require 'thread'

module Libuv
    class Reactor
        include Resource, Assertions
        extend Accessors


        REACTORS = ThreadSafe::Cache.new
        CRITICAL = Mutex.new


        module ClassMethods
            # Get default reactor
            # 
            # @return [::Libuv::Reactor]
            def default
                return @default unless @default.nil?
                CRITICAL.synchronize {
                    return @default ||= create(::Libuv::Ext.default_loop)
                }
            end

            # Create new Libuv reactor
            # 
            # @return [::Libuv::Reactor]
            def new(&blk)
                thread = create(::Libuv::Ext.loop_new)
                if block_given?
                    ::Thread.new do
                        thread.run &blk
                    end
                end
                thread
            end

            # Build a Ruby Libuv reactor from an existing reactor pointer
            # 
            # @return [::Libuv::Reactor]
            def create(pointer)
                allocate.tap { |i| i.send(:initialize, FFI::AutoPointer.new(pointer, ::Libuv::Ext.method(:loop_delete))) }
            end

            # Checks for the existence of a reactor on the current thread
            #
            # @return [::Libuv::Reactor | nil]
            def current
                REACTORS[Thread.current]
            end
        end
        extend ClassMethods


        # Initialize a reactor using an FFI::Pointer to a libuv reactor
        def initialize(pointer) # :notnew:
            @pointer = pointer
            @reactor = self
            @run_count = 0

            # Create an async call for scheduling work from other threads
            @run_queue = Queue.new
            @process_queue = @reactor.async method(:process_queue_cb)
            @process_queue.unref

            # Create a next tick timer
            @next_tick = @reactor.timer method(:next_tick_cb)
            @next_tick.unref

            # Create an async call for ending the reactor
            @stop_reactor = @reactor.async method(:stop_cb)
            @stop_reactor.unref

            # Libuv can prevent the application shutting down once the main thread has ended
            # The addition of a prepare function prevents this from happening.
            @reactor_prep = Libuv::Prepare.new(@reactor, method(:noop))
            @reactor_prep.unref
            @reactor_prep.start

            # LibUV ingnores program interrupt by default.
            # We provide normal behaviour and allow this to be overriden
            @on_signal = proc { stop_cb }
            sig_callback = method(:signal_cb)
            self.signal(:INT, sig_callback).unref
            self.signal(:HUP, sig_callback).unref
            self.signal(:TERM, sig_callback).unref
        end

        attr_reader :run_count


        protected


        def noop; end

        def stop_cb
            REACTORS.delete(@reactor_thread)
            @reactor_thread = nil

            ::Libuv::Ext.stop(@pointer)
        end

        def signal_cb
            @on_signal.call(self)
        end

        def next_tick_cb
            @next_tick_scheduled = false
            @next_tick.unref
            process_queue_cb
        end

        def process_queue_cb
            # ensure we only execute what was required for this tick
            length = @run_queue.length
            length.times do
                process_item
            end
        end

        def process_item
            begin
                run = @run_queue.pop true  # pop non-block
                run.call
            rescue Exception => e
                @reactor.log :error, :next_tick_cb, e
            end
        end


        public


        # Overwrite as errors in jRuby can literally hang VM when inspecting
        # as many many classes will reference this class
        def inspect
            "#<#{self.class}:0x#{self.__id__.to_s(16)} NT=#{@run_queue.length}>"
        end


        def handle; @pointer; end

        # Run the actual event reactor. This method will block until the reactor is stopped.
        #
        # @param run_type [:UV_RUN_DEFAULT, :UV_RUN_ONCE, :UV_RUN_NOWAIT]
        # @yieldparam promise [::Libuv::Q::Promise] Yields a promise that can be used for logging unhandled
        #   exceptions on the reactor.
        def run(run_type = :UV_RUN_DEFAULT)
            if @reactor_thread.nil?
                @reactor_notify = @reactor.defer

                begin
                    @reactor_thread = ::Thread.current
                    raise 'only one reactor allowed per-thread' if REACTORS[@reactor_thread]

                    REACTORS[@reactor_thread] = @reactor
                    if block_given?
                        ::Fiber.new { yield @reactor }.resume
                    end
                    @run_count += 1
                    ::Libuv::Ext.run(@pointer, run_type)  # This is blocking
                ensure
                    REACTORS.delete(@reactor_thread)
                    @reactor_thread = nil
                    @run_queue.clear
                end
            elsif block_given?
                schedule { ::Fiber.new { yield @reactor }.resume }
            end

            @reactor
        end


        # Provides a promise notifier for receiving un-handled exceptions
        #
        # @return [::Libuv::Q::Promise]
        def notifier(callback = nil, &blk)
            @reactor_notify.promise.progress(callback || blk)
        end

        # Creates a deferred result object for where the result of an operation may only be returned 
        # at some point in the future or is being processed on a different thread (thread safe)
        #
        # @return [::Libuv::Q::Deferred]
        def defer
            Q.defer(@reactor)
        end

        # Combines multiple promises into a single promise that is resolved when all of the input
        # promises are resolved. (thread safe)
        #
        # @param *promises [::Libuv::Q::Promise] a number of promises that will be combined into a single promise
        # @return [::Libuv::Q::Promise] Returns a single promise that will be resolved with an array of values,
        #   each value corresponding to the promise at the same index in the `promises` array. If any of
        #   the promises is resolved with a rejection, this resulting promise will be resolved with the
        #   same rejection.
        def all(*promises)
            Q.all(@reactor, *promises)
        end

        #
        # Combines multiple promises into a single promise that is resolved when any of the input
        # promises are resolved.
        #
        # @param *promises [::Libuv::Q::Promise] a number of promises that will be combined into a single promise
        # @return [::Libuv::Q::Promise] Returns a single promise
        def any(*promises)
            Q.any(@reactor, *promises)
        end

        #
        # Combines multiple promises into a single promise that is resolved when all of the input
        # promises are resolved or rejected.
        #
        # @param *promises [::Libuv::Q::Promise] a number of promises that will be combined into a single promise
        # @return [::Libuv::Q::Promise] Returns a single promise that will be resolved with an array of values,
        #   each [result, wasResolved] value pair corresponding to a at the same index in the `promises` array.
        def finally(*promises)
            Q.finally(@reactor, *promises)
        end
        

        # forces reactor time update, useful for getting more granular times
        # 
        # @return nil
        def update_time
            ::Libuv::Ext.update_time(@pointer)
        end

        # Get current time in milliseconds
        # 
        # @return [Fixnum]
        def now
            ::Libuv::Ext.now(@pointer)
        end

        # Lookup an error code and return is as an error object
        #
        # @param err [Integer] The error code to look up.
        # @return [::Libuv::Error]
        def lookup_error(err)
            name = ::Libuv::Ext.err_name(err)

            if name
                msg  = ::Libuv::Ext.strerror(err)
                ::Libuv::Error.const_get(name.to_sym).new(msg)
            else
                # We want a back-trace in this case
                raise "error lookup failed for code #{err}"
            end
        rescue Exception => e
            @reactor.log :warn, :error_lookup_failed, e
            e
        end

        # Get a new TCP instance
        # 
        # @return [::Libuv::TCP]
        def tcp(callback = nil, &blk)
            callback ||= blk
            TCP.new(@reactor, progress: callback)
        end

        # Get a new UDP instance
        #
        # @return [::Libuv::UDP]
        def udp
            UDP.new(@reactor)
        end

        # Get a new TTY instance
        # 
        # @param fileno [Integer] Integer file descriptor of a tty device
        # @param readable [true, false] Boolean indicating if TTY is readable
        # @return [::Libuv::TTY]
        def tty(fileno, readable = false)
            assert_type(Integer, fileno, "io#fileno must return an integer file descriptor, #{fileno.inspect} given")

            TTY.new(@reactor, fileno, readable)
        end

        # Get a new Pipe instance
        # 
        # @param ipc [true, false] indicate if a handle will be used for ipc, useful for sharing tcp socket between processes
        # @return [::Libuv::Pipe]
        def pipe(ipc = false)
            Pipe.new(@reactor, ipc)
        end

        # Get a new timer instance
        # 
        # @param callback [Proc] the callback to be called on timer trigger
        # @return [::Libuv::Timer]
        def timer(callback = nil, &blk)
            Timer.new(@reactor, callback || blk)
        end

        # Get a new Prepare handle
        # 
        # @return [::Libuv::Prepare]
        def prepare(callback = nil, &blk)
            Prepare.new(@reactor, callback || blk)
        end

        # Get a new Check handle
        # 
        # @return [::Libuv::Check]
        def check(callback = nil, &blk)
            Check.new(@reactor, callback || blk)
        end

        # Get a new Idle handle
        # 
        # @param callback [Proc] the callback to be called on idle trigger
        # @return [::Libuv::Idle]
        def idle(callback = nil, &block)
            Idle.new(@reactor, callback || block)
        end

        # Get a new Async handle
        # 
        # @return [::Libuv::Async]
        def async(callback = nil, &block)
            callback ||= block
            handle = Async.new(@reactor)
            handle.progress callback if callback
            handle
        end

        # Get a new signal handler
        # 
        # @return [::Libuv::Signal]
        def signal(signum = nil, callback = nil, &block)
            callback ||= block
            handle = Signal.new(@reactor)
            handle.progress callback if callback
            handle.start(signum) if signum
            handle
        end

        # Allows user defined behaviour when sig int is received
        def on_program_interrupt(callback = nil, &block)
            @on_signal = callback || block
            self
        end

        # Queue some work for processing in the libuv thread pool
        #
        # @param callback [Proc] the callback to be called in the thread pool
        # @return [::Libuv::Work]
        # @raise [ArgumentError] if block is not given
        def work(callback = nil, &block)
            callback ||= block
            assert_block(callback)
            Work.new(@reactor, callback)    # Work is a promise object
        end

        # Lookup a hostname
        #
        # @param hostname [String] the domain name to lookup
        # @param port [Integer, String] the service being connected too
        # @param callback [Proc] the callback to be called on success
        # @return [::Libuv::Dns]
        def lookup(hostname, hint = :IPv4, port = 9, &block)
            dns = Dns.new(@reactor, hostname, port, hint)    # Work is a promise object
            dns.then block if block_given?
            dns
        end

        # Get a new FSEvent instance
        # 
        # @param path [String] the path to the file or folder for watching
        # @return [::Libuv::FSEvent]
        # @raise [ArgumentError] if path is not a string
        def fs_event(path)
            assert_type(String, path)
            FSEvent.new(@reactor, path)
        end

        # Opens a file and returns an object that can be used to manipulate it
        #
        # @param path [String] the path to the file or folder for watching
        # @param flags [Integer] see ruby File::Constants
        # @param mode [Integer]
        # @return [::Libuv::File]
        def file(path, flags = 0, mode = 0)
            assert_type(String, path, "path must be a String")
            assert_type(Integer, flags, "flags must be an Integer")
            assert_type(Integer, mode, "mode must be an Integer")
            File.new(@reactor, path, flags, mode)
        end

        # Returns an object for manipulating the filesystem
        #
        # @return [::Libuv::Filesystem]
        def filesystem
            Filesystem.new(@reactor)
        end

        # Schedule some work to be processed on the event reactor as soon as possible (thread safe)
        #
        # @param callback [Proc] the callback to be called on the reactor thread
        # @raise [ArgumentError] if block is not given
        def schedule(callback = nil, &block)
            callback ||= block
            assert_block(callback)

            if reactor_thread?
                callback.call
            else
                @run_queue << callback
                @process_queue.call
            end
        end

        # Queue some work to be processed in the next iteration of the event reactor (thread safe)
        #
        # @param callback [Proc] the callback to be called on the reactor thread
        # @raise [ArgumentError] if block is not given
        def next_tick(callback = nil, &block)
            callback ||= block
            assert_block(callback)

            @run_queue << callback
            if reactor_thread?
                # Create a next tick timer
                if not @next_tick_scheduled
                    @next_tick.start(0)
                    @next_tick_scheduled = true
                    @next_tick.ref
                end
            else
                @process_queue.call
            end
        end

        # Notifies the reactor there was an event that should be logged
        #
        # @param level [Symbol] the error level (info, warn, error etc)
        # @param id [Object] some kind of identifying information
        # @param *args [*args] any additional information
        def log(level, id, *args)
            @reactor_notify.notify(level, id, *args)
        end

        # Closes handles opened by the reactor class and completes the current reactor iteration (thread safe)
        def stop
            @stop_reactor.call
        end

        # True if the calling thread is the same thread as the reactor.
        #
        # @return [Boolean]
        def reactor_thread?
            @reactor_thread == ::Thread.current
        end

        # Exposed to allow joining on the thread, when run in a multithreaded environment. Performing other actions on the thread has undefined semantics (read: a dangerous endevor).
        #
        # @return [Thread]
        attr_reader :reactor_thread

        # Tells you whether the Libuv reactor reactor is currently running.
        #
        # @return [Boolean]
        def reactor_running?
            !@reactor_thread.nil?
        end
    end
end
