# Pre-processes the official references.json.gz dataset into the
# binary format consumed via mmap by the runtime. Run once at Docker
# build time; the runtime image carries only the `.bin` file.
#
# Usage:
#   preprocess [INPUT.json.gz] [OUTPUT.bin]
#
# Defaults to "resources/references.json.gz" and "resources/references.bin".

require "compress/gzip"
require "./references"

input  = ARGV[0]? || "resources/references.json.gz"
output = ARGV[1]? || "resources/references.bin"

started = Time.instant

STDERR.puts "[preprocess] reading #{input}"
STDERR.flush

count = 0
File.open(input, "rb") do |file|
  Compress::Gzip::Reader.open(file) do |gz|
    File.open(output, "wb") do |bin|
      count = RinhaDeBackend::References.preprocess(gz, bin)
    end
  end
end

elapsed = (Time.instant - started).total_seconds.round(2)
size = File.size(output)
STDERR.puts "[preprocess] wrote #{count} records to #{output} " \
            "(#{(size / 1024.0 / 1024.0).round(1)} MiB) in #{elapsed}s"
