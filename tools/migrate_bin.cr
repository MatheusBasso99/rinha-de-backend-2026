require "../src/references"

# Migrates an RNH4 (stride-14) references.bin into the new RNH5
# (stride-16) layout used by the AVX2 VPMADDWD kernel. Each row is
# rewritten with two trailing zero pad lanes; the IVF metadata
# (cell offsets, radii, bbox) is preserved as-is, just re-padded to
# the new stride.
#
# Usage: crystal run --release tools/migrate_bin.cr -- INPUT.bin OUTPUT.bin
#
# Lets us A/B the kernel locally without re-running the multi-minute
# k-means in `preprocess.cr`.

OLD_DIMS  = 14
NEW_DIMS  = 16
OLD_MAGIC = "RNH4"
NEW_MAGIC = "RNH5"

# Repad a stride-14 row block into a stride-16 row block; pad lanes
# (indices 14, 15) stay 0 (set by Slice initializer).
def repad(src_ptr : Int16*, rows : Int32) : Slice(Int16)
  out = Slice(Int16).new(rows.to_i64 * NEW_DIMS, 0_i16)
  out_ptr = out.to_unsafe
  i = 0
  while i < rows
    src = src_ptr + i * OLD_DIMS
    dst = out_ptr + i * NEW_DIMS
    j = 0
    while j < OLD_DIMS
      dst[j] = src[j]
      j &+= 1
    end
    i &+= 1
  end
  out
end

input  = ARGV[0]? || "resources/references.bin.rnh4"
output = ARGV[1]? || "resources/references.bin"

raise "input #{input} missing" unless File.exists?(input)

input_size = File.size(input)
STDERR.puts "[migrate] reading #{input} (#{(input_size / 1024.0 / 1024.0).round(1)} MiB)"

bytes = File.read(input).to_slice
base  = bytes.to_unsafe

magic_str = String.new(base, 4)
raise "magic mismatch: got #{magic_str.inspect}, expected #{OLD_MAGIC.inspect}" unless magic_str == OLD_MAGIC

count           = (base + 4).as(UInt32*).value.to_i32
dims            = (base + 8).as(UInt32*).value.to_i32
k               = (base + 12).as(UInt32*).value.to_i32
max_cell_radius = (base + 16).as(UInt32*).value
raise "expected old dims=#{OLD_DIMS}, got #{dims}" unless dims == OLD_DIMS

STDERR.puts "[migrate] count=#{count} k=#{k} max_cell_radius=#{max_cell_radius}"

# Old layout offsets (stride 14).
header_size       = 64
old_vectors_off   = header_size
old_labels_off    = old_vectors_off + count * OLD_DIMS * sizeof(Int16)
old_centroids_off = old_labels_off + count * sizeof(UInt8)
old_celloff_off   = old_centroids_off + k * OLD_DIMS * sizeof(Int16)
old_radius_off    = old_celloff_off + (k + 1) * sizeof(UInt32)
old_bmin_off      = old_radius_off + k * sizeof(UInt32)
old_bmax_off      = old_bmin_off + k * OLD_DIMS * sizeof(Int16)
old_end           = old_bmax_off + k * OLD_DIMS * sizeof(Int16)
raise "size mismatch: input #{input_size} != computed #{old_end}" unless input_size == old_end

old_vectors_ptr   = (base + old_vectors_off).as(Int16*)
old_labels_ptr    = (base + old_labels_off).as(UInt8*)
old_centroids_ptr = (base + old_centroids_off).as(Int16*)
old_celloff_ptr   = (base + old_celloff_off).as(UInt32*)
old_radius_ptr    = (base + old_radius_off).as(UInt32*)
old_bmin_ptr      = (base + old_bmin_off).as(Int16*)
old_bmax_ptr      = (base + old_bmax_off).as(Int16*)

new_vectors   = repad(old_vectors_ptr, count)
new_centroids = repad(old_centroids_ptr, k)
new_bmin      = repad(old_bmin_ptr, k)
new_bmax      = repad(old_bmax_ptr, k)

# Empty-cell sentinel sweep: in the old format every empty cell had
# bbox_min[c][j] = Int16::MAX and bbox_max[c][j] = Int16::MIN across all
# 14 logical lanes. With the wider stride the pad lanes (indices 14, 15)
# default to 0; against a zero-padded query, lanes (lo=0, hi=0, q=0)
# contribute 0 and bbox_d would land at 0 for an otherwise-rejected
# empty cell. Force lanes 14, 15 to the same (Int16::MAX, Int16::MIN)
# sentinel so the bbox check still rejects every query.
i = 0
while i < k
  start = old_celloff_ptr[i]
  stop  = old_celloff_ptr[i + 1]
  if start == stop
    bb_off = i * NEW_DIMS
    new_bmin[bb_off + 14] = Int16::MAX
    new_bmin[bb_off + 15] = Int16::MAX
    new_bmax[bb_off + 14] = Int16::MIN
    new_bmax[bb_off + 15] = Int16::MIN
  end
  i += 1
end

STDERR.puts "[migrate] writing #{output}"
File.open(output, "wb") do |io|
  # Header.
  io.write(NEW_MAGIC.to_slice)
  io.write_bytes(count.to_u32, IO::ByteFormat::LittleEndian)
  io.write_bytes(NEW_DIMS.to_u32, IO::ByteFormat::LittleEndian)
  io.write_bytes(k.to_u32, IO::ByteFormat::LittleEndian)
  io.write_bytes(max_cell_radius, IO::ByteFormat::LittleEndian)
  io.write(Bytes.new(header_size - 20, 0_u8))

  # Sections.
  io.write(new_vectors.to_unsafe_bytes)
  io.write(Slice(UInt8).new(old_labels_ptr, count).to_unsafe_bytes)
  io.write(new_centroids.to_unsafe_bytes)
  io.write(Slice(UInt32).new(old_celloff_ptr, k + 1).to_unsafe_bytes)
  io.write(Slice(UInt32).new(old_radius_ptr, k).to_unsafe_bytes)
  io.write(new_bmin.to_unsafe_bytes)
  io.write(new_bmax.to_unsafe_bytes)
end

new_size = File.size(output)
STDERR.puts "[migrate] wrote #{new_size} bytes (#{(new_size / 1024.0 / 1024.0).round(1)} MiB)"
