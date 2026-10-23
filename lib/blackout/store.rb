# frozen_string_literal: true

CACHE  = File.join(Dir.home, '.cache', 'blackout')
CONFIG = File.join(Dir.home, '.config', 'blackout.json')
STATE  = File.join(CACHE, 'state.json')

# File.write FOLLOWS a symlink: a link planted in the cache would have us
# overwrite someone else's file with network data. Renaming replaces the
# link itself, and makes the write atomic as a side effect.
def atomic_write(path, body)
  tmp = "#{path}.#{Process.pid}.tmp"
  File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(body) }
  File.rename(tmp, path)
rescue StandardError
  FileUtils.rm_f(tmp)
  raise
end

# touch follows a symlink too, and would stamp someone else's file
def touch_cache(path)
  FileUtils.touch(path) unless File.symlink?(path)
end

# Cache and config are the owner's alone
def ensure_dir(dir)
  # If the directory itself is a link, our files would land in someone
  # else's folder and could replace what already sits there
  raise "refusing symlinked dir: #{dir}" if File.symlink?(dir)

  FileUtils.mkdir_p(dir, mode: 0o700)
end

# Reading the cache can fail on a damaged file too
def read_cache(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue StandardError
  nil
end

# An ETag only means something while its cache is readable. Otherwise
# the server answers 304 to an empty or broken file and the data never
# loads again — silently, and for good.
def read_etag(path)
  return nil unless File.exist?("#{path}.etag")
  return nil unless read_cache(path)

  etag = File.read("#{path}.etag")
  # This goes into If-None-Match. Ruby rejects CR/LF itself, but it
  # would happily send a megabyte-long "ETag" from a tampered file
  etag if etag.match?(/\A[\x20-\x7e]{1,200}\z/)
rescue StandardError
  nil
end

def write_etag(path, etag)
  etag ? atomic_write("#{path}.etag", etag) : FileUtils.rm_f("#{path}.etag")
rescue StandardError
  nil
end

def load_config
  File.exist?(CONFIG) ? JSON.parse(File.read(CONFIG, encoding: 'UTF-8')) : {}
rescue StandardError
  {}
end

def save_config(cfg)
  ensure_dir(File.dirname(CONFIG))
  atomic_write(CONFIG, JSON.pretty_generate(cfg))
end

def load_state
  File.exist?(STATE) ? JSON.parse(File.read(STATE)) : {}
rescue StandardError
  {}
end

def save_state(st)
  ensure_dir(CACHE)
  atomic_write(STATE, JSON.generate(st))
end
