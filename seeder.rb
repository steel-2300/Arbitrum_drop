require 'eth'
require 'forwardable'
require 'parallel'
require 'colorize'

require_relative './common/rpc'
require_relative './common/logger'
require_relative './common/helpers'

class Seeder
  include Helpers

  class EmptyPrivateKeys < StandardError; end
  class BadPrivateKey < StandardError; end
  class BadTransferAddress < StandardError; end
  class SelfTransferDetected < StandardError; end

  def start
    pre_loop_actions
    main_loop
  end

  private

  attr_reader :rpc, :latest_l1_block, :private_keys_map, :seeders_balances, :stolen_balances, :transactions_map, :transactions_statuses, :stolens_claimables, :stolens_balances, :required_eth_balance_statuses
  attr_reader :settings
  attr_reader :threads_count, :amount_to_send, :l1_block_start_period, :rpcs_list, :erc20_token_contract_hash, :claimer_contract_hash, :gas_limit_for_transfer_eth_tx

  def pre_loop_actions
    load_settings_as_instance_vars("#{File.dirname(__FILE__)}/seeder/seeder_settings.yml")
    @rpc = Rpc.new(rpcs_list)
    @private_keys_map = check_and_get_wallets_private_keys
    @seeders_balances = {}
    @stolen_balances = {}
    @total_transferred = {}
    @transactions_map = {}
    @transactions_statuses = {}
    @stolens_claimables = {}
    @stolens_balances = {}
    @required_eth_balance_statuses = {}

    load_balances
    display_total_info
  end

  def check_and_get_wallets_private_keys
    raw_wallets = File.readlines("#{File.dirname(__FILE__)}/seeder/wallets.txt")

    correct_private_keys = []

    raw_wallets.each.with_index(1) do |w, line|
      private_key = w.scan(/[0-9a-fA-F]{64}/)[0].to_s.downcase
      raise BadPrivateKey.new("Line: #{line} seeder/wallets.txt") if private_key.empty?

      from_address = Eth::Key.new(priv: private_key).address.to_s.downcase
      transfer_address = w.scan(/0[xX][0-9a-fA-F]{40}/)[0].to_s.downcase

      raise BadTransferAddress.new("Line: #{line} seeder/wallets.txt") if private_key.empty?
      # TODO: validate pair address should not be duplicated, PK - can
      # raise DuplicatePrivateKey.new("PK: #{masked_string(private_key)} Line: #{line} seeder/wallets.txt") if correct_private_keys.include?(private_key)
      raise SelfTransferDetected.new("Address #{transfer_address} for same private key: #{masked_string(private_key)} Line: #{line} seeder/wallets.txt") if from_address == transfer_address

      correct_private_keys << [private_key, transfer_address]
    end

    raise EmptyPrivateKeys.new("Add list of private keys to seeder/wallets.txt") if correct_private_keys.empty?

    correct_private_keys
  end

  def main_loop
    i = 0
    while true
      main_loop_block_wrapper do
        if l1_block_start_period <= get_current_l1_block
          do_seeding
          check_tx_states
          load_balances
          display_total_info

          break if (stolens_claimables.values.sum + stolens_balances.values.sum) == 0
        else
          blocks_diff = l1_block_start_period - latest_l1_block
          if i % 5 == 0 && blocks_diff > 3
            load_balances
            display_total_info
          end
          puts Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z") + " Current L1 Block number: #{latest_l1_block} Blocks until target (#{l1_block_start_period}): #{blocks_diff.to_s} (~#{(blocks_diff * 12.5).to_i} seconds) RPC: #{rpc.get_rpc}"
        end
      end
      i += 1
    end
  end

  def do_seeding
    Parallel.map_with_index(private_keys_map, in_threads: threads_count) do |(private_key, transfer_address), index|
      seed_per_wallet(private_key, transfer_address)
    end
  end

  def seed_per_wallet(private_key, transfer_address)
    @seeders_balances[private_key] = eth_balance(private_key)
    @stolen_balances[transfer_address] = eth_balance(transfer_address)

    # TODO: conditions for transfer
    return if seeders_balances[private_key] == 0
    return if stolen_balances[transfer_address] >= amount_to_send
    return if (stolens_claimables[transfer_address].to_i + stolens_balances[transfer_address].to_i) == 0

    # TODO: make correct
    gas_limit = (gas_limit_for_transfer_eth_tx || retryable_eth_client(:eth_estimate_gas, {})["result"].to_i(16) * 1.3).to_i

    required_eth_for_tx = gas_limit * gwei_for_client * Eth::Unit::GWEI
    required_eth_for_tx += amount_to_send
    required_eth_balance_statuses[private_key] = [seeders_balances[private_key] >= required_eth_for_tx, required_eth_for_tx]

    return if !required_eth_balance_statuses[private_key][0]

    txid = retryable_eth_client([:transfer, gas_limit], transfer_address, amount_to_send, sender_key: Eth::Key.new(priv: private_key), legacy: true)
    transactions_map[[private_key, transfer_address]] = txid

    @total_transferred[[private_key, transfer_address]] ||= 0
    @total_transferred[[private_key, transfer_address]] += amount_to_send
    # receipt = retryable_eth_client(:eth_get_transaction_receipt, txid)['result']
    # @status_str = "txid: #{txid}. success: #{receipt['status'].to_i(16) == 1}"
  end

  def load_balances
    Parallel.map_with_index(private_keys_map, in_threads: threads_count) do |(private_key, transfer_address), index|
      stolens_claimables[transfer_address] = retryable_eth_client(:call, Eth::Contract.from_abi(**claimer_contract_hash), "claimableTokens", transfer_address)
      stolens_balances[transfer_address] = retryable_eth_client(:call, Eth::Contract.from_abi(**erc20_token_contract_hash), "balanceOf", transfer_address)
      seeders_balances[private_key] = eth_balance(private_key)
      stolen_balances[transfer_address] = eth_balance(transfer_address)
    end
  end

  def check_tx_states
    Parallel.map_with_index(private_keys_map, in_threads: threads_count) do |(private_key, transfer_address), index|
      txid = transactions_map[[private_key, transfer_address]]
      if !txid.nil?
        receipt = retryable_eth_client(:eth_get_transaction_receipt, txid)['result']
        if !receipt.nil?
          transactions_statuses[txid] = receipt.dig('status').to_i(16)
        end
      end
    end
  end

  def display_total_info
    info_string = "#{Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z")} RPC: #{rpc.get_rpc} #{"="*40}"
    puts "\n\n"
    puts info_string
    private_keys_map.each.with_index(1) do |(private_key, transfer_address), index|
      seeder_wei_balance = seeders_balances[private_key]
      stolen_wei_balance = stolen_balances[transfer_address]
      last_tx = transactions_map[[private_key, transfer_address]]
      tx_state = transactions_statuses[last_tx]

      rounded_seeder_eth = (BigDecimal(seeder_wei_balance) / Eth::Unit::ETHER).truncate(7).to_s("F")
      rounded_stolen_eth = (BigDecimal(stolen_wei_balance) / Eth::Unit::ETHER).truncate(7).to_s("F")

      estimated_seeder_eth_in_usd = (rounded_seeder_eth.to_f * ETH_PRICE).round(2)

      seeder_eth_color = amount_to_send < seeder_wei_balance.to_f ? :green : :red

      # TODO: if amount more than required for claim and transfer tokens
      stolen_eth_color =
        if stolen_wei_balance > 0.0005 * Eth::Unit::ETHER
          :green
        elsif stolen_wei_balance > 0.00003 * Eth::Unit::ETHER
          :orange
        else
          :red
        end

      tx_color =
        if tx_state == 1
          :blue
        elsif tx_state == 0
          :red
        end

      claimable_wei_token_balance = stolens_claimables[transfer_address]
      inwallet_wei_token_balance = stolens_balances[transfer_address]

      claimable_token_color, inwallet_token_color =
        if claimable_wei_token_balance == 0 && inwallet_wei_token_balance == 0
          [:red, :red]
        elsif claimable_wei_token_balance > 0 && inwallet_wei_token_balance == 0
          [:green, nil]
        elsif claimable_wei_token_balance == 0 && inwallet_wei_token_balance > 0
          [nil, :green]
        else
          [:green, :green]
        end

      rounded_claimable_token_balance = (BigDecimal(claimable_wei_token_balance) / Eth::Unit::ETHER).truncate(5).to_s("F").to_i.to_s.colorize(claimable_token_color)
      rounded_inwallet_token_balance = (BigDecimal(inwallet_wei_token_balance) / Eth::Unit::ETHER).truncate(5).to_s("F").to_i.to_s.colorize(inwallet_token_color)

      notice =
        if claimable_wei_token_balance == 0 && inwallet_wei_token_balance == 0
          "Nothing on stolen (skipping)".red
        elsif stolen_wei_balance > amount_to_send * Eth::Unit::ETHER
          "All right (skipping)".green
        elsif stolen_wei_balance < amount_to_send * Eth::Unit::ETHER && !required_eth_balance_statuses[private_key].nil? && required_eth_balance_statuses[private_key][0] == false
          "Seeder wallet havent #{(BigDecimal(required_eth_balance_statuses[private_key][1]) / Eth::Unit::ETHER).truncate(7).to_s("F")} to seed".red
        end

      puts "#{index.to_s.rjust(3)} #{masked_string(private_key)} #{masked_string(Eth::Key.new(priv: private_key).address.to_s)} -> #{transfer_address}"
      puts "Seeder ETH balance: #{rounded_seeder_eth.to_s.rjust(8).colorize(seeder_eth_color)} (~$#{estimated_seeder_eth_in_usd.to_s.rjust(9)}}) Stolen ETH balance: #{rounded_stolen_eth.rjust(8).colorize(stolen_eth_color)} Claimable ARB: #{rounded_claimable_token_balance} Balance ARB: #{rounded_inwallet_token_balance} TX: #{(last_tx || '-----').to_s.colorize(tx_color)} #{notice} "
      puts ""
    end
    puts info_string
  end
end

Seeder.new.start
