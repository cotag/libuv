module Libuv
    module Stream


        BACKLOG_ERROR = "backlog must be an Integer".freeze
        WRITE_ERROR = "data must be a String".freeze
        STREAM_CLOSED_ERROR = "unable to write to a closed stream".freeze
        CLOSED_HANDLE_ERROR = "handle closed before accept called".freeze


        def listen(backlog)
            return if @closed
            assert_type(Integer, backlog, BACKLOG_ERROR)
            error = check_result ::Libuv::Ext.listen(handle, Integer(backlog), callback(:on_listen))
            reject(error) if error
        end

        # Starts reading from the handle
        def start_read
            return if @closed
            error = check_result ::Libuv::Ext.read_start(handle, callback(:on_allocate), callback(:on_read))
            reject(error) if error
        end

        # Stops reading from the handle
        def stop_read
            return if @closed
            error = check_result ::Libuv::Ext.read_stop(handle)
            reject(error) if error
        end

        # Shutsdown the writes on the handle waiting until the last write is complete before triggering the callback
        def shutdown
            return if @closed
            error = check_result ::Libuv::Ext.shutdown(::Libuv::Ext.create_request(:uv_shutdown), handle, callback(:on_shutdown))
            reject(error) if error
        end

        def write(data)
            # NOTE:: Similar to udp.rb -> send
            deferred = @loop.defer
            if !@closed
                begin
                    assert_type(String, data, WRITE_ERROR)

                    size         = data.respond_to?(:bytesize) ? data.bytesize : data.size
                    buffer       = ::Libuv::Ext.buf_init(FFI::MemoryPointer.from_string(data), size)

                    # local as this variable will be avaliable until the handle is closed
                    @write_callbacks ||= []

                    #
                    # create the curried callback
                    #
                    callback = FFI::Function.new(:void, [:pointer, :int]) do |req, status|
                        ::Libuv::Ext.free(req)
                        # remove the callback from the array
                        # assumes writes are done in order
                        promise = @write_callbacks.shift[0]
                        resolve promise, status
                    end


                    @write_callbacks << [deferred, callback]
                    req = ::Libuv::Ext.create_request(:uv_write)
                    error = check_result ::Libuv::Ext.write(req, handle, buffer, 1, callback)

                    if error
                        @write_callbacks.pop
                        ::Libuv::Ext.free(req)
                        deferred.reject(error)

                        reject(error)       # close the handle
                    end
                rescue Exception => e
                    deferred.reject(e)  # this write exception may not be fatal
                end
            else
                deferred.reject(RuntimeError.new(STREAM_CLOSED_ERROR))
            end
            deferred.promise
        end

        def readable?
            return false if @closed
            ::Libuv::Ext.is_readable(handle) > 0
        end

        def writable?
            return false if @closed
            ::Libuv::Ext.is_writable(handle) > 0
        end

        def progress(callback = nil, &blk)
            @progress = callback || blk
        end


        private


        def on_listen(server, status)
            e = check_result(status)

            if e
                reject(e)   # is this cause for closing the handle?
            else
                begin
                    @on_listen.call(self)
                rescue Exception => e
                    @loop.log :error, :stream_listen_cb, e
                end
            end
        end

        def on_allocate(client, suggested_size, buffer)
            buffer[:len] = suggested_size
            buffer[:base] = ::Libuv::Ext.malloc(suggested_size)
        end

        def on_read(handle, nread, buf)
            e = check_result(nread)
            base = buf[:base]

            if e
                ::Libuv::Ext.free(base)
                # I assume this is desirable behaviour
                if e.is_a? ::Libuv::Error::EOF
                    close   # Close gracefully 
                else
                    reject(e)
                end
            else
                data = base.read_string(nread)
                ::Libuv::Ext.free(base)
                
                if @tls.nil?
                    begin
                        @progress.call data, self
                    rescue Exception => e
                        @loop.log :error, :stream_progress_cb, e
                    end
                else
                    @tls.decrypt(data)
                end
            end
        end

        def on_shutdown(req, status)
            ::Libuv::Ext.free(req)
            @close_error = check_result(status)
            close
        end
    end
end