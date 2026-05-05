# Crystal bindings for h2o/picohttpparser. The .c is vendored under
# `src/ext/picohttpparser/`; the Makefile and the Dockerfile compile it
# to `picohttpparser.o` before `crystal build` runs, and `__DIR__` lets
# us point the linker at the resulting object regardless of the build
# CWD.
@[Link(ldflags: "#{__DIR__}/ext/picohttpparser/picohttpparser.o")]
lib LibPicoHTTP
  struct PhrHeader
    name : LibC::Char*
    name_len : LibC::SizeT
    value : LibC::Char*
    value_len : LibC::SizeT
  end

  # Returns >= 0 on success (number of bytes consumed by request line +
  # headers, body starts at that offset), -2 if the request is partial,
  # -1 on malformed input.
  fun phr_parse_request(buf : LibC::Char*, len : LibC::SizeT,
                        method : LibC::Char**, method_len : LibC::SizeT*,
                        path : LibC::Char**, path_len : LibC::SizeT*,
                        minor_version : LibC::Int*,
                        headers : PhrHeader*, num_headers : LibC::SizeT*,
                        last_len : LibC::SizeT) : LibC::Int
end
