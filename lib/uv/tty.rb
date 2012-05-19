module UV
  class TTY
    include Stream, Handle, Resource, Listener

    def initialize(loop, fd, readable = true)
      @fd = Integer(fd)
      raise "not a tty" unless UV.guess_handle(@fd) == :uv_tty
      ObjectSpace.define_finalizer(self, UV.method(:tty_reset_mode))
      @readable = readable
      super(loop)
    end

    def enable_raw_mode
      check_result! UV.tty_set_mode(handle, 1)
    end

    def disable_raw_mode
      check_result! UV.tty_set_mode(handle, 0)
    end

    def winsize
      width = FFI::MemoryPointer.new(:int)
      height = FFI::MemoryPointer.new(:int)
      uv_tty_get_winsize(handle, width, height)
      [width.get_int(0), height.get_int(0)]
    end

    private
    def create_handle
      ptr = UV.create_handle(:uv_tty)
      check_result! UV.tty_init(loop.to_ptr, ptr, @fd, @readable ? 1 : 0)
      @fd = @readable = nil
      ptr
    end
  end
end