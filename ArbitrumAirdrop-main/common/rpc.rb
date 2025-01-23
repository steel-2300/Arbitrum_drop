class Rpc
  class EmptyRpcList < StandardError; end

  def initialize(list)
    # TODO: validate rpcs chain ids
    @list = list
  end

  def get_rpc
    @current_rpc ||=
      if list.empty?
        raise EmptyRpcList.new
      else
        # list[0]
        list.sample
        # TODO: create randomify
      end
  end

  def change_rpc
    @used_rpcs ||= []
    @used_rpcs << current_rpc
    
    diff = list - used_rpcs
    next_rpc =
      if diff.empty?
        @used_rpcs = []
        list[0]
        list.sample
      else
        diff[0]
        diff.sample
      end
    sleep 1
    @current_rpc = next_rpc
  end

  private

  attr_reader :current_rpc, :used_rpcs, :list
end
