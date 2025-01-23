require 'eth'
require 'forwardable'
require 'parallel'
require 'colorize'

require_relative './common/rpc'
require_relative './common/logger'
require_relative './common/helpers'

class Transferer
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

  attr_reader :private_keys_map
  attr_reader :ethers_balances, :tokens_balances, :total_transferred_tokens, :required_eth_balance_statuses
  attr_reader :rpc, :changing_rpc_now
  attr_reader :rpcs_list, :threads_count, :eth_border, :erc20_token_contract_hash, :gas_limit_for_transfer_tx

  def pre_loop_actions
    load_settings_as_instance_vars("#{File.dirname(__FILE__)}/transferer/transferer_settings.yml")
    @rpc = Rpc.new(rpcs_list)
    @private_keys_map = check_and_get_wallets_private_keys

    @ethers_balances = {}
    @tokens_balances = {}
    @total_transferred_tokens = {}
    @required_eth_balance_statuses = {}
  end

  def check_and_get_wallets_private_keys
    raw_wallets = File.readlines("#{File.dirname(__FILE__)}/transferer/wallets.txt")

    correct_private_keys = {}

    raw_wallets.each.with_index(1) do |w, line|
      private_key = w.scan(/[0-9a-fA-F]{64}/)[0].to_s.downcase
      raise BadPrivateKey.new("Line: #{line} transferer/wallets.txt") if private_key.empty?

      from_address = Eth::Key.new(priv: private_key).address.to_s.downcase
      transfer_address = w.scan(/0[xX][0-9a-fA-F]{40}/)[0].to_s.downcase

      raise BadTransferAddress.new("Line: #{line} transferer/wallets.txt") if private_key.empty?
      raise DuplicatePrivateKey.new("PK: #{masked_string(private_key)} Line: #{line} transferer/wallets.txt") if correct_private_keys.include?(private_key)
      raise SelfTransferDetected.new("Address #{transfer_address} for same private key: #{masked_string(private_key)} Line: #{line} transferer/wallets.txt") if from_address == transfer_address

      correct_private_keys[private_key] = transfer_address
    end

    raise EmptyPrivateKeys.new("Add list of private keys to transferer/wallets.txt") if correct_private_keys.empty?

    correct_private_keys
  end

  def main_loop
    while true
      main_loop_block_wrapper do
        Parallel.map_with_index(private_keys_map, in_threads: threads_count) do |(private_key, transfer_address), index|
          do_possible_transfer(private_key, transfer_address)
        end
        display_total_info
      end
    end
  end

  def do_possible_transfer(private_key, transfer_address)
    @ethers_balances[private_key] = eth_balance(private_key)
    @tokens_balances[private_key] = token_balance(private_key)

    return if tokens_balances[private_key] == 0
    # if tokens_balances[private_key] > 0

    eth_key = Eth::Key.new(priv: private_key)
    index = private_keys_map.keys.index(private_key) + 1
    # puts "doing transfer for #{index} #{eth_key.address.to_s}"

    eth_contract = Eth::Contract.from_abi(**erc20_token_contract_hash)

    fn = "transfer"
    args = [transfer_address, tokens_balances[private_key]]

    params = {
      data: retryable_eth_client(:__send__, :call_payload, eth_contract.functions.find { |f| f.name == fn }, args),
      from: eth_key.address.to_s,
      to: eth_contract.address
    }

    gas_limit = (gas_limit_for_transfer_tx || (retryable_eth_client(:eth_estimate_gas, params)["result"].to_i(16) * 1.3).to_i).to_i

    required_eth_for_tx = gas_limit * gwei_for_client * Eth::Unit::GWEI
    required_eth_balance_statuses[private_key] = [ethers_balances[private_key] >= required_eth_for_tx, required_eth_for_tx]

    return if !required_eth_balance_statuses[private_key][0]

    # pp "#{ethers_balances[private_key]} #{gwei_for_client} #{gas_limit}"
    txid =
      retryable_eth_client(:transact_and_wait,
        eth_contract,
        fn,
        *args,
        sender_key: eth_key,
        gas_limit: gas_limit,
      )

    if !txid.nil?
      receipt = retryable_eth_client(:eth_get_transaction_receipt, txid)['result']
      @total_transferred_tokens[private_key] ||= 0
      @total_transferred_tokens[private_key] += tokens_balances[private_key]
    end
  end

  def display_total_info
    info_string = "#{Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z")} RPC: #{rpc.get_rpc} #{"="*40}"
    puts "\n\n"
    puts info_string
    private_keys_map.each.with_index(1) do |(private_key, transfer_address), index|
      eth_key = Eth::Key.new(priv: private_key)
      eth_wei_balance = ethers_balances[private_key]
      token_wei_balance = tokens_balances[private_key]
      transferred_tokens_wei_balance = total_transferred_tokens[private_key]

      rounded_eth = (BigDecimal(eth_wei_balance) / Eth::Unit::ETHER).truncate(5).to_s("F")

      estimated_eth_in_usd = (rounded_eth.to_f * ETH_PRICE).round(2)
      rounded_token = (BigDecimal(token_wei_balance) / Eth::Unit::ETHER).truncate(2).to_s("F").to_i

      eth_color =
        if token_wei_balance > 0
          eth_border < rounded_eth.to_f ? :green : :red
        end
      transferrable_color = rounded_token > 0 ? :green : nil

      notice =
        if token_wei_balance > 0 && !required_eth_balance_statuses[private_key].nil? && required_eth_balance_statuses[private_key][0] == false
          required_rounded = (BigDecimal(required_eth_balance_statuses[private_key][1]) / Eth::Unit::ETHER).truncate(5).to_s("F")
          eth_color = :red
          "Need ETH #{required_rounded}".red
        elsif token_wei_balance == 0
          "Nothing for transfer (waiting)".red
        end

      total_rounded =
        if !total_transferred_tokens[private_key].nil?
          clr = total_transferred_tokens[private_key] > 0 ? :blue : nil
          ((BigDecimal(total_transferred_tokens[private_key]) / Eth::Unit::ETHER).truncate(2).to_s("F").to_i).to_s.colorize(clr)
        end

      puts "#{index.to_s.rjust(3)} #{masked_string(private_key)} #{masked_string(eth_key.address.to_s)} -> #{transfer_address} Transferable: #{rounded_token.to_s.rjust(5).colorize(transferrable_color)} ETH balance: #{rounded_eth.rjust(8).colorize(eth_color)} (~$#{estimated_eth_in_usd.to_s.rjust(9)}}) Total: #{total_rounded}  #{notice}"
    end
    puts info_string
  end

  def token_balance(private_key)
    retryable_eth_client(:call, Eth::Contract.from_abi(**erc20_token_contract_hash), "balanceOf", Eth::Key.new(priv: private_key).address.to_s)
  end

end

Transferer.new.start
