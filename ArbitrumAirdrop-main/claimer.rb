require 'eth'
require 'forwardable'
require 'parallel'
require 'colorize'

require_relative './common/rpc'
require_relative './common/logger'
require_relative './common/helpers'

class Claimer
  include Helpers

  class BadPrivateKey < StandardError; end
  class DuplicatePrivateKey < StandardError; end
  class EmptyPrivateKeys < StandardError; end

  def start
    pre_loop_actions
    main_loop
  end

  private

  attr_reader :latest_l1_block, :private_keys, :private_keys_for_claim, :rpc
  attr_reader :ethers_balances, :claimable_amounts, :claim_tx_statuses, :required_eth_balance_statuses, :claim_times
  attr_reader :changing_rpc_now, :claim_started_at

  attr_reader :settings, :l1_block_start_period, :threads_count, :rpcs_list, :claimer_contract_hash, :eth_border, :claim_function_name, :gas_limit_for_claim_tx

  def pre_loop_actions
    load_settings_as_instance_vars("#{File.dirname(__FILE__)}/claimer/claimer_settings.yml")
    @rpc = Rpc.new(rpcs_list)
    @private_keys = check_and_get_wallets_private_keys

    @claim_tx_statuses = {}
    @required_eth_balance_statuses = {}
    @claim_times = {}

    reload_and_display_main_info
  end

  def reload_and_display_main_info
    @ethers_balances = load_ethers_on_wallets
    @claimable_amounts = load_claimable_amounts
    display_pre_loop_info
  end

  def display_pre_loop_info
    info_string = "#{Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z")} RPC: #{rpc.get_rpc} #{"="*40}"
    puts "\n\n"
    puts info_string
    private_keys.each.with_index(1) do |private_key, index|
      eth_key = Eth::Key.new(priv: private_key)
      eth_wei_balance = ethers_balances[private_key]
      claimable_amount_in_wei = claimable_amounts[private_key]

      rounded_eth = (BigDecimal(eth_wei_balance) / Eth::Unit::ETHER).truncate(5).to_s("F")

      estimated_eth_in_usd = (rounded_eth.to_f * ETH_PRICE).round(2)
      rounded_claimable = (BigDecimal(claimable_amount_in_wei) / Eth::Unit::ETHER).truncate(2).to_s("F").to_i

      eth_color = eth_border < rounded_eth.to_f ? :green : :red
      claimable_color = rounded_claimable > 0 ? :green : :red

      notice =
        if !required_eth_balance_statuses[private_key].nil? && required_eth_balance_statuses[private_key][0] == false
          required_rounded = (BigDecimal(required_eth_balance_statuses[private_key][1]) / Eth::Unit::ETHER).truncate(5).to_s("F")
          eth_color = :red
          "Need ETH #{required_rounded}".red
        elsif claim_tx_statuses[private_key] == 1
          claim_time = (claim_times[private_key] - claim_started_at).to_i
          "#{"Claimed".blue} #{claim_time.to_s.rjust(2)} sec"
        elsif claimable_color == :green && eth_color == :red
          "Not enough eth for claim".red
        elsif claimable_color == :red
          "Nothing for claim".red
        elsif claimable_color == :green && eth_color == :green
          @private_keys_for_claim ||= []
          @private_keys_for_claim << private_key
          "All right, will be claimed ASAP".green
        end

      puts "#{index.to_s.rjust(3)} #{masked_string(private_key)} #{eth_key.address.to_s} Claimable: #{rounded_claimable.to_s.rjust(5).colorize(claimable_color)} ETH balance: #{rounded_eth.rjust(8).colorize(eth_color)} (~$#{estimated_eth_in_usd.to_s.rjust(9)}}) #{notice}"
    end
    puts info_string
  end

  def main_loop
    i = 0
    while true
      main_loop_block_wrapper do
        if l1_block_start_period <= get_current_l1_block
          pre_claim_info
          do_claim
          reload_and_display_main_info

          break if claimable_amounts.values.sum == 0
        else
          blocks_diff = l1_block_start_period - latest_l1_block
          reload_and_display_main_info if i % 5 == 0 && blocks_diff > 3
          puts Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z") + " Current L1 Block number: #{latest_l1_block} Blocks until target (#{l1_block_start_period}): #{blocks_diff.to_s} (~#{(blocks_diff * 12.5).to_i} seconds) RPC: #{rpc.get_rpc}"
        end
      end
      i += 1
    end
  end

  def pre_claim_info
    @claim_started_at ||= Time.now
    puts ("!"*40).yellow
    puts ("!"*40).yellow
    puts "Claim started at #{claim_started_at}".yellow
    puts ("!"*40).yellow
    puts ("!"*40).yellow
  end

  def check_and_get_wallets_private_keys
    raw_wallets = File.readlines("#{File.dirname(__FILE__)}/claimer/wallets.txt")

    correct_private_keys = []

    raw_wallets.each.with_index(1) do |w, line|
      private_key = w.scan(/[0-9a-fA-F]{64}/)[0].to_s.downcase
      raise BadPrivateKey.new("Line: #{line} claimer/wallets.txt") if private_key.empty?
      raise DuplicatePrivateKey.new("PK: #{masked_string(private_key)} Line: #{line} claimer/wallets.txt") if correct_private_keys.include?(private_key)

      correct_private_keys << private_key
    end

    raise EmptyPrivateKeys.new("Add list of private keys to claimer/wallets.txt") if correct_private_keys.empty?

    correct_private_keys
  end

  def load_ethers_on_wallets
    Parallel.map_with_index(private_keys, in_threads: threads_count) do |private_key, index|
      [private_key, eth_balance(private_key)]
    end.to_h
  end

  def load_claimable_amounts
    Parallel.map_with_index(private_keys, in_threads: threads_count) do |private_key, index|
      eth_key = Eth::Key.new(priv: private_key)
      eth_contract = Eth::Contract.from_abi(**claimer_contract_hash)

      claimable_amount_in_wei = retryable_eth_client(:call, eth_contract, "claimableTokens", eth_key.address.to_s)
      [private_key, claimable_amount_in_wei]
    end.to_h
  end

  def do_claim
    Parallel.map(private_keys, in_threads: threads_count) do |private_key|
      claim_per_wallet(private_key)
    end
  end

  def claim_per_wallet(private_key)
    eth_key = Eth::Key.new(priv: private_key)
    index = private_keys.index(private_key) + 1
    # TODO: move to log
    # puts "doing claim for #{index} #{eth_key.address.to_s}"

    if claimable_amounts[private_key] == 0
      # TODO: log into about claimless wallet
      return
    end

    # # TODO: Remove it!
    # return if ARGV[0] != "goerli"

    eth_contract = Eth::Contract.from_abi(**claimer_contract_hash)
    params = {
      data: retryable_eth_client(:__send__, :call_payload, eth_contract.functions.find { |f| f.name == claim_function_name }, []),
      from: eth_key.address.to_s,
      to: eth_contract.address
    }

    gas_limit = (gas_limit_for_claim_tx || retryable_eth_client(:eth_estimate_gas, params)["result"].to_i(16) * 1.3).to_i

    required_eth_for_tx = gas_limit * gwei_for_client * Eth::Unit::GWEI
    ethers_balances[private_key] = eth_balance(private_key)
    required_eth_balance_statuses[private_key] = [ethers_balances[private_key] >= required_eth_for_tx, required_eth_for_tx]

    return if !required_eth_balance_statuses[private_key][0]

    txid =
      retryable_eth_client(:transact,
        eth_contract,
        claim_function_name,
        sender_key: eth_key,
        gas_limit: gas_limit,
      )
    retryable_eth_client(:wait_for_tx, txid)

    receipt = retryable_eth_client(:eth_get_transaction_receipt, txid)['result']
    @claim_tx_statuses[private_key] = receipt['status'].to_i(16) if !receipt.nil?
    claim_times[private_key] = Time.now
  rescue IOError => e
    if e.message.include?("insufficient funds")
      puts "no funds #{index} #{eth_key.address} #{e.inspect}"
    else
      raise e
    end
  end
end

Claimer.new.start
