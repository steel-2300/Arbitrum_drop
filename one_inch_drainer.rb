require_relative './common/rpc'
require_relative './common/logger'
require_relative './common/helpers'

require 'eth'
require 'forwardable'
require 'parallel'
require 'colorize'

class OneInchDrain
  include Helpers

  def start
    pre_loop_actions
    main_loop
  end

  private

  attr_reader :private_key, :approve_address, :swap_if_price_higher, :amount_to_swap, :swap_to_token, :erc20_token_contract_hash, :claimer_contract_hash, :rpcs_list, :proxy_list, :slippage, :eth_border
  attr_reader :token_balance, :claimable_balance, :approve_balance, :eth_wallet_balance, :current_ratio
  attr_reader :rpc, :gwei_for_client, :latest_tx_id

  def pre_loop_actions
    load_settings_as_instance_vars("#{File.dirname(__FILE__)}/one_inch_drainer/one_inch_drainer_settings.yml")
    @rpc = Rpc.new(rpcs_list)
  end

  def eth_key
    Eth::Key.new(priv: private_key)
  end

  def load_tokens_balance
    @token_balance = retryable_eth_client(:call, Eth::Contract.from_abi(**erc20_token_contract_hash), "balanceOf", eth_key.address.to_s)
  end

  def load_eth_balance
    @eth_wallet_balance = eth_balance(eth_key.address.to_s)
  end

  def load_claimable_balance
    @claimable_balance = retryable_eth_client(:call, Eth::Contract.from_abi(**claimer_contract_hash), "claimableTokens", eth_key.address.to_s)
  end

  def load_approve_balance
    @approve_balance = retryable_eth_client(:call, Eth::Contract.from_abi(**erc20_token_contract_hash), "allowance", eth_key.address.to_s, approve_address)
    if @approve_balance == 0
      eth_contract = Eth::Contract.from_abi(**erc20_token_contract_hash)
      fn = "approve"
      args = [approve_address, 2 ** 256 - 1]

      params = {
        data: retryable_eth_client(:__send__, :call_payload, eth_contract.functions.find { |f| f.name == fn }, args),
        from: eth_key.address.to_s,
        to: eth_contract.address
      }

      gas_limit = (retryable_eth_client(:eth_estimate_gas, params)["result"].to_i(16) * 1.3).to_i

      retryable_eth_client(:transact,
        eth_contract,
        fn,
        *args,
        sender_key: eth_key,
        gas_limit: gas_limit,
      )
    end
  rescue IOError => e
    if e.message.include?("insufficient funds for gas")
      puts "APPROVE FAILED"
      puts "#{e.inspect}"
    else
      raise e
    end
  end

  def try_swap
    request_params = {
      fromTokenAddress: erc20_token_contract_hash[:address],
      toTokenAddress: swap_to_token,
      amount: (amount_to_swap * (10 ** 18)).to_i,
      fromAddress: eth_key.address.to_s,
      slippage: slippage
    }#.merge(params.slice(:protocols, :fee, :gasLimit, :connectorTokens, :complexityLevel, :mainRouteParts, :parts, :gasPrice, :fromAddress, :slippage))  
    query_params_string = URI.encode_www_form(request_params.compact.to_a)

    response_json = 
      Timeout::timeout(5) do
        JSON.parse(Net::HTTP.get_response(URI("https://api.1inch.io/v5.0/42161/swap?#{query_params_string}")).body)
      end


    @current_ratio = 
      (response_json.dig('toTokenAmount').to_i / (10 ** response_json.dig('toToken', 'decimals').to_i).to_f) /
      (response_json.dig('fromTokenAmount').to_i / (10 ** response_json.dig('fromToken', 'decimals').to_i).to_f)

    if current_ratio > swap_if_price_higher
      do_swap(response_json)
    end

    p [request_params, response_json]
  end

  def do_swap(pre_swap_params)
    tx_params = pre_swap_params["tx"]
    params = {
      value: tx_params["value"].to_i,
      gas_limit: tx_params["gas"],
      chain_id: 42161,
      to: tx_params["to"],
      data: tx_params["data"],
      from: tx_params["from"],
      nonce: retryable_eth_client(:get_nonce, tx_params["from"]),
      gas_price: tx_params["gasPrice"].to_i
    }
    tx = Eth::Tx.new(params)
    tx.sign(eth_key)

    @latest_tx_id = retryable_eth_client(:eth_send_raw_transaction, tx.hex)['result']
  end

  def main_loop
    while true
      main_loop_block_wrapper do
        Parallel.each([
          "load_approve_balance",
          "load_eth_balance",
          "load_tokens_balance",
          "load_claimable_balance"
        ], in_threads: 10) { |method| self.send(method)}
        try_swap
        display_info
      end
    end
  end

  def display_info
    puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z")} RPC: #{rpc.get_rpc} #{"="*40}"

    if token_balance == 0 && claimable_balance
      balance_color = :red
      claimable_color = :red
    end
    
    rounded_eth = (BigDecimal(eth_wallet_balance) / Eth::Unit::ETHER).truncate(5).to_s("F")
    estimated_eth_in_usd = (rounded_eth.to_f * ETH_PRICE).round(2)
    eth_color = eth_border < rounded_eth.to_f ? :green : :red

    rounded_token = (BigDecimal(token_balance) / Eth::Unit::ETHER).truncate(5).to_s("F")
    rounded_claimable = (BigDecimal(claimable_balance) / Eth::Unit::ETHER).truncate(5).to_s("F")

    notice = nil
    token_color =
      if token_balance == 0 && claimable_balance == 0
        :red
      elsif token_balance > 0
        :green
      end
    claimable_color =
      if token_balance == 0 && claimable_balance == 0
        :red
      elsif claimable_balance > 0
        :green
      end

    rounded_approved =
      if approve_balance >= amount_to_swap
        "YES".green
      else
        "NO".red
      end

    rounded_ratio = current_ratio.to_s
    ratio_color =
      if current_ratio > swap_if_price_higher
        notice = "WILL DO SWAP".green
        :green
      end

    rounded_amount_to_swap = amount_to_swap.to_s
    amount_to_swap_color = amount_to_swap <= rounded_token.to_f || amount_to_swap <= rounded_claimable.to_f ? :green : :red

    puts "#{masked_string(private_key)} #{masked_string(eth_key.address.to_s)} ETH balance: #{rounded_eth.colorize(eth_color)} (~$#{estimated_eth_in_usd.to_s}}) Token balance: #{rounded_token.colorize(token_color)}. Claimable: #{rounded_claimable.colorize(claimable_color)}. Approved: #{rounded_approved}. Ratio: #{rounded_ratio.colorize(ratio_color)}. Need ratio: #{swap_if_price_higher}. Amount to swap: #{rounded_amount_to_swap.colorize(amount_to_swap_color)}. #{notice}. TXID: #{latest_tx_id}"
    puts "\n\n"
  end
end

OneInchDrain.new.start
