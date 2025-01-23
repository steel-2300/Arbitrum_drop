require 'yaml'
require 'erb'

module Eth
  module Tx
    def validate_params(fields)
      if fields[:nonce].nil? or fields[:nonce] < 0
        raise ParameterError, "Invalid signer nonce #{fields[:nonce]}!"
      end
      if fields[:gas_limit].nil? or fields[:gas_limit] < DEFAULT_GAS_LIMIT# or fields[:gas_limit] > BLOCK_GAS_LIMIT
        raise ParameterError, "Invalid gas limit #{fields[:gas_limit]}!"
      end
      unless fields[:value] >= 0
        raise ParameterError, "Invalid transaction value #{fields[:value]}!"
      end
      unless fields[:access_list].nil? or fields[:access_list].is_a? Array
        raise ParameterError, "Invalid access list #{fields[:access_list]}!"
      end
      return fields
    end
  end
end

module Helpers
  class NotPrivateKeyNotAddress < StandardError; end

  attr_reader :gwei_for_client, :proxy_list

  ETH_PRICE = 1_800

  def retryable_eth_client(method_or_params, ...)
    method =
      if method_or_params.is_a?(Array)
        method_or_params[0]
      else
        method_or_params
      end

    gas_limit =
      if method_or_params.is_a?(Array)
        method_or_params[1]
      end

    c = Eth::Client.create(rpc.get_rpc)
    c.max_fee_per_gas = (gwei_for_client * Eth::Unit::GWEI).to_i
    c.max_priority_fee_per_gas = (gwei_for_client * Eth::Unit::GWEI).to_i
    c.gas_limit = gas_limit if !gas_limit.nil?

    set_proxy
    current_proxy = ENV['http_proxy']

    Timeout::timeout(5) do
      c.public_send(method, ...)
    end
  rescue IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET, JSON::ParserError, Net::OpenTimeout, SocketError, Errno::ECONNRESET, Net::ReadTimeout, Errno::ETIMEDOUT, Eth::Client::ContractExecutionError, Timeout::Error, Errno::ECONNREFUSED, Net::HTTPClientException, Errno::EPIPE => e
    # current_proxy = nil
    if e.message.include?("Too Many Requests") || e.message.include?("Rate Limit") || e.message.include?("SSL_connect") || e.message.include?("Failed to open TCP") || e.message.include?("getaddrinfo") || e.message.include?("reset by peer") || e.message.include?("SSL_read") || e.message.include?("Net::ReadTimeout") || e.message.include?("Exceeded the quota usage") || e.message.include?("unexpected token at") || e.message.include?("timed out") || e.message.include?("throughput") || e.message.include?("compute units") || e.is_a?(Timeout::Error) || e.message.include?("Broken pipe")  || e.message.include?("forcibly closed by") || e.message.include?("we can't execute this request") || e.message.include?("Internal server error")
      if !@changing_rpc_now
        @changing_rpc_now = true
        puts "RPC Rate limit error. Changing rpc. Errored: #{rpc.get_rpc}. New: #{rpc.change_rpc}. Proxy: #{current_proxy}"
        @changing_rpc_now = false
      end
      # sleep 1
      retry
    elsif e.message.include?("Proxy Authentication Required")
      puts "Proxy problem: #{current_proxy}"
    elsif e.message.include?("nonce too low")
      puts "bad nonce, retrying"
      retry
    else
      puts "#{rpc.get_rpc} #{current_proxy}"
      raise e
    end
  end

  def masked_string(string, first_chars = 4, last_chars = 4)
    "#{string[0..first_chars]}***#{string[-last_chars..-1]}"
  end

  def eth_balance(private_key_or_address)
    if private_key_or_address.size == 64
      retryable_eth_client(:get_balance, Eth::Key.new(priv: private_key_or_address).address.to_s.downcase)
    elsif private_key_or_address.size == 42
      retryable_eth_client(:get_balance, private_key_or_address)
    else
      NotPrivateKeyNotAddress.new(private_key_or_address)
    end
  end

  def get_current_l1_block
    eth_contract = Eth::Contract.from_abi(name: "Multicall2", address: "0x842eC2c7D803033Edf55E478F461FC547Bc54EB2", abi: '[{"inputs":[{"components":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"callData","type":"bytes"}],"internalType":"struct Multicall2.Call[]","name":"calls","type":"tuple[]"}],"name":"aggregate","outputs":[{"internalType":"uint256","name":"blockNumber","type":"uint256"},{"internalType":"bytes[]","name":"returnData","type":"bytes[]"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"components":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"callData","type":"bytes"}],"internalType":"struct Multicall2.Call[]","name":"calls","type":"tuple[]"}],"name":"blockAndAggregate","outputs":[{"internalType":"uint256","name":"blockNumber","type":"uint256"},{"internalType":"bytes32","name":"blockHash","type":"bytes32"},{"components":[{"internalType":"bool","name":"success","type":"bool"},{"internalType":"bytes","name":"returnData","type":"bytes"}],"internalType":"struct Multicall2.Result[]","name":"returnData","type":"tuple[]"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"blockNumber","type":"uint256"}],"name":"getBlockHash","outputs":[{"internalType":"bytes32","name":"blockHash","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getBlockNumber","outputs":[{"internalType":"uint256","name":"blockNumber","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getCurrentBlockCoinbase","outputs":[{"internalType":"address","name":"coinbase","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getCurrentBlockDifficulty","outputs":[{"internalType":"uint256","name":"difficulty","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getCurrentBlockGasLimit","outputs":[{"internalType":"uint256","name":"gaslimit","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getCurrentBlockTimestamp","outputs":[{"internalType":"uint256","name":"timestamp","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"addr","type":"address"}],"name":"getEthBalance","outputs":[{"internalType":"uint256","name":"balance","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getL1BlockNumber","outputs":[{"internalType":"uint256","name":"l1BlockNumber","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getLastBlockHash","outputs":[{"internalType":"bytes32","name":"blockHash","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bool","name":"requireSuccess","type":"bool"},{"components":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"callData","type":"bytes"}],"internalType":"struct Multicall2.Call[]","name":"calls","type":"tuple[]"}],"name":"tryAggregate","outputs":[{"components":[{"internalType":"bool","name":"success","type":"bool"},{"internalType":"bytes","name":"returnData","type":"bytes"}],"internalType":"struct Multicall2.Result[]","name":"returnData","type":"tuple[]"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bool","name":"requireSuccess","type":"bool"},{"components":[{"internalType":"address","name":"target","type":"address"},{"internalType":"bytes","name":"callData","type":"bytes"}],"internalType":"struct Multicall2.Call[]","name":"calls","type":"tuple[]"}],"name":"tryBlockAndAggregate","outputs":[{"internalType":"uint256","name":"blockNumber","type":"uint256"},{"internalType":"bytes32","name":"blockHash","type":"bytes32"},{"components":[{"internalType":"bool","name":"success","type":"bool"},{"internalType":"bytes","name":"returnData","type":"bytes"}],"internalType":"struct Multicall2.Result[]","name":"returnData","type":"tuple[]"}],"stateMutability":"nonpayable","type":"function"}]')
    @latest_l1_block = retryable_eth_client(:call, eth_contract, "getL1BlockNumber")

    if @latest_l1_block.nil?
      @latest_l1_block = retryable_eth_client(:eth_get_block_by_number, 'latest', false)["result"]["l1BlockNumber"].to_i(16)
    end

    @latest_l1_block
  end

  def load_settings_as_instance_vars(path)
    mode = ARGV[0] || "production"

    @settings = YAML.load(ERB.new(File.read(path)).result)
    @settings.dig(@settings.keys.first, mode).each do |setting_name, value|
      v =
        case value
        when Hash
          value.transform_keys(&:to_sym)
        else
          value
        end
      self.instance_variable_set("@#{setting_name}", v)
    end
  end

  def main_loop_block_wrapper
    yield
  rescue IOError, Eth::Client::ContractExecutionError => e
    if e.message.include?("max fee per gas less")
      puts "Need new gwei #{e.message}"
      puts @gwei_for_client = (retryable_eth_client(:eth_gas_price)['result'].to_i(16) / Eth::Unit::GWEI).round(2) + 0.02
      puts "New gwei info: #{gwei_for_client}"
      retry
    # elsif e.message.include?("nonce too low")
    #   puts "bad nonce, retrying"
    #   retry
    # elsif e.message.include?("TokenDistributor: nothing to claim")
    #   puts "some transactiong error with nothing to claim from TokenDistributor"
    #   retry
    else
      raise e
    end
  end

  def set_proxy
    ENV['http_proxy'] = (proxy_list || []).sample
  end
end
