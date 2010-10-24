require 'drb/drb'
require 'sudo/support/kernel'
require 'sudo/support/process'
require 'sudo/constants'
require 'sudo/system'
require 'sudo/proxy'

begin
  DRb.current_server
rescue DRb::DRbServerNotFound
  DRb.start_service
end

module Sudo
  class Wrapper

    class RuntimeError              < RuntimeError;       end
    class NotRunning                < RuntimeError;       end
    class SudoFailed                < RuntimeError;       end
    class SudoProcessExists         < RuntimeError;       end
    class SudoProcessAlreadyExists  < SudoProcessExists;  end
    class NoValidSocket             < RuntimeError;       end
    class SocketNotFound            < NoValidSocket;      end
    class NoValidSudoPid            < RuntimeError;       end
    class SudoProcessNotFound       < NoValidSudoPid;     end

    class << self

      # With blocks.
      # +ruby_opts+ are the command line options to the sudo ruby interpreter
      def run(ruby_opts)
        sudo = new(ruby_opts)
        yield sudo.start!
        sudo.stop!
      end 

      # Not an instance method, so it may act as a finalizer
      # (as in ObjectSpace.define_finalizer)
      def cleanup!(h)
        Sudo::System.kill   h[:pid]
        Sudo::System.unlink h[:socket]
      end

    end

    # +ruby_opts+ are the command line options to the sudo ruby interpreter
    def initialize(ruby_opts='') 
      @proxy      = nil
      @socket     = "/tmp/rubysu-#{Process.pid}-#{object_id}" 
      @sudo_pid   = nil
      @ruby_opts  = ruby_opts
    end

    def server_uri; "drbunix:#{@socket}"; end
    
    def start! 
      Sudo::System.check
      
      @sudo_pid = spawn( 
"sudo ruby -I#{LIBDIR} #{@ruby_opts} #{SERVER_SCRIPT} #{@socket} #{Process.uid}"
      ) 
      Process.detach(@sudo_pid) if @sudo_pid # avoid zombies
      ObjectSpace.define_finalizer self, Finalizer.new(
          :pid => @sudo_pid, :socket => @socket
      )

      if wait_for(:timeout => 1){File.exists? @socket}
        @proxy = DRbObject.new_with_uri(server_uri)
      else
        raise RuntimeError, "Couldn't create DRb socket #{@socket}"  
      end

      load_features

      self
    end

    def load_features
      $LOADED_FEATURES.each do |feature|
        self[Kernel].require feature
      end
    end

    def running?
      true if (
        @sudo_pid and Process.exists? @sudo_pid and
        @socket   and File.exists?    @socket   and
        @proxy
      )
    end

    def stop!
      self.class.cleanup!(:pid => @sudo_pid, :socket => @socket)
      @proxy = nil

    end

    def [](object)
      if running?
        MethodProxy.new object, @proxy
      else
        raise NotRunning
      end
    end

    # Inspired by Remover class in tmpfile.rb (Ruby std library)
    class Finalizer
      def initialize(h)
        @data = h
      end

      # mimic proc-like behavior (walk like a duck)
      def call(*args)
        Sudo::Wrapper.cleanup! @data
      end
    end

  end
end
