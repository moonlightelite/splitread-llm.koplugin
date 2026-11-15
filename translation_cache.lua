-- Persistent translation cache: one folder per book, one file per target language.
--
--   <KOReader data dir>/splitread_cache/<book name>_<hash>/<language code>.jsonl
--
-- A translation is saved the moment it arrives and found again after the book was
-- closed or KOReader restarted, so a page is never paid for twice (a Google or
-- Gemini call, or a slow local model). Translations into different languages
-- live in different files, so a language can be looked at, cleared or evicted on
-- its own, and only the language being read is loaded into memory. Inside a
-- file the key also holds the provider, the source language and, for the local
-- LLM, the model and system prompt (see splitread:getCachePrefix).
--
-- Size limit: the cache of all books together may take at most `max_mb`
-- megabytes (0 = no limit). When a save pushes it over, the least recently used
-- language files of other books and languages are deleted first; if the language
-- being read still does not fit, its oldest entries go (reading an entry makes it
-- the newest).
--
-- File format: one JSON object per line, {"k": key, "t": text}. Saving appends a
-- line (cheap; a crash can at worst cut the last line, which is skipped on load);
-- a file is rewritten only to drop old entries.

local DataStorage = require("datastorage")
local logger = require("logger")

local DEFAULT_MAX_MB = 20
local EVICT_TO = 0.9        -- when over the limit, free space down to this fraction of it
local SLACK_LINES = 200     -- superseded lines tolerated before a file is rewritten

local function jsonEncode(tbl)
    local ok, res = pcall(function() return require("json").encode(tbl) end)
    if ok and type(res) == "string" then return res end
    return nil
end

local function jsonDecode(line)
    local ok, res = pcall(function() return require("json").decode(line) end)
    if ok and type(res) == "table" then return res end
    return nil
end

local function getLfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs or nil
end

-- Short, stable fingerprint of a string (two independent modular hashes plus
-- the length), for cache keys and folder names. Not cryptographic.
local function hash(s)
    s = tostring(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 33 + b) % 2147483647
        h2 = (h2 * 131 + b) % 2147483629
    end
    return string.format("%08x%08x%x", h1, h2, #s)
end

------------------------------------------------------------------------------
-- Partition: the entries of one book in one language (one file).
------------------------------------------------------------------------------

local Partition = {}
Partition.__index = Partition

local function newPartition(path, on_change)
    return setmetatable({ path = path, entries = {}, n = 0, bytes = 0, seq = 0, lines = 0, loaded = false }, Partition)
end

function Partition:load()
    if self.loaded then return end
    self.loaded = true
    if not self.path then return end
    local f = io.open(self.path, "rb")
    if not f then return end
    local lines = 0
    for line in f:lines() do
        lines = lines + 1
        local rec = jsonDecode(line)
        if rec and type(rec.k) == "string" and type(rec.t) == "string" then
            local old = self.entries[rec.k]
            if old then self.bytes = self.bytes - old.size else self.n = self.n + 1 end
            self.seq = self.seq + 1
            -- a later line replaces an earlier one with the same key
            self.entries[rec.k] = { t = rec.t, seq = self.seq, size = #line + 1 }
            self.bytes = self.bytes + #line + 1
        end
    end
    f:close()
    self.lines = lines
    local lfs = getLfs()
    if lfs and lfs.touch then pcall(lfs.touch, self.path) end   -- "recently used"
    if lines > self.n + SLACK_LINES then self:rewrite() end
end

function Partition:unload()
    self.entries, self.n, self.bytes, self.lines, self.loaded = {}, 0, 0, 0, false
end

-- Rewrites the file with exactly the entries in memory (oldest first).
function Partition:rewrite()
    if not self.path then return end
    if self.n == 0 then
        os.remove(self.path)
        self.lines = 0
        return
    end
    local order = {}
    for k, e in pairs(self.entries) do order[#order + 1] = { k = k, e = e } end
    table.sort(order, function(a, b) return a.e.seq < b.e.seq end)
    local tmp = self.path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    local lines = 0
    for _, item in ipairs(order) do
        local line = jsonEncode({ k = item.k, t = item.e.t })
        if line then
            f:write(line, "\n")
            lines = lines + 1
        end
    end
    f:close()
    if os.rename(tmp, self.path) then
        self.lines = lines
    else
        os.remove(tmp)
    end
end

function Partition:get(key)
    self:load()
    local e = self.entries[key]
    if not e then return nil end
    self.seq = self.seq + 1
    e.seq = self.seq          -- reading makes an entry the newest
    return e.t
end

-- `ensure_dir` creates the folder of the file before the first write.
function Partition:put(key, text, ensure_dir)
    self:load()
    local line = self.path and jsonEncode({ k = key, t = text })
    local size = (line and #line or (#key + #text + 20)) + 1
    local old = self.entries[key]
    if old then self.bytes = self.bytes - old.size else self.n = self.n + 1 end
    self.seq = self.seq + 1
    self.entries[key] = { t = text, seq = self.seq, size = size }
    self.bytes = self.bytes + size

    if self.path and line then
        if ensure_dir then ensure_dir() end
        local f = io.open(self.path, "ab")
        if f then
            f:write(line, "\n")
            f:close()
            self.lines = self.lines + 1
        end
    end
end

-- Drops the oldest entries until at most `target` bytes remain; rewrites the file.
function Partition:trimTo(target)
    self:load()
    if self.bytes <= target then return 0 end
    local order = {}
    for k, e in pairs(self.entries) do order[#order + 1] = { k = k, seq = e.seq } end
    table.sort(order, function(a, b) return a.seq < b.seq end)
    local removed = 0
    for _, item in ipairs(order) do
        if self.bytes <= target then break end
        local e = self.entries[item.k]
        self.entries[item.k] = nil
        self.bytes = self.bytes - e.size
        self.n = self.n - 1
        removed = removed + 1
    end
    self:rewrite()
    return removed
end

------------------------------------------------------------------------------
-- TranslationCache: the cache of one book (all of its languages).
------------------------------------------------------------------------------

local TranslationCache = {}
TranslationCache.__index = TranslationCache
TranslationCache.hash = hash
TranslationCache.DEFAULT_MAX_MB = DEFAULT_MAX_MB

function TranslationCache.getDir()
    return DataStorage:getDataDir() .. "/splitread_cache"
end

local function mkdir(path)
    local lfs = getLfs()
    if lfs then lfs.mkdir(path) end -- harmless if it already exists
end

-- <cache dir>/<readable name>_<hash of the full path>
function TranslationCache.bookDirFor(book_path)
    local base = book_path:match("([^/\\]+)$") or "book"
    base = base:gsub("%.[^.]*$", ""):gsub("[^%w]", "_"):sub(1, 40)
    return string.format("%s/%s_%s", TranslationCache.getDir(), base, hash(book_path))
end

-- File name part for a language code ("zh-TW" stays "zh-TW").
local function langFile(lang)
    lang = tostring(lang or ""):gsub("[^%w%-]", "_")
    if lang == "" then lang = "other" end
    return lang
end

-- `book_path` nil gives a cache that only lives in memory.
function TranslationCache.open(book_path, max_mb)
    local self = setmetatable({ parts = {}, active = nil }, TranslationCache)
    if type(book_path) == "string" and book_path ~= "" then
        self.dir = TranslationCache.bookDirFor(book_path)
    end
    self:setMaxMB(max_mb == nil and DEFAULT_MAX_MB or max_mb)
    return self
end

function TranslationCache:setMaxMB(mb)
    mb = tonumber(mb) or DEFAULT_MAX_MB
    self.max_bytes = mb > 0 and math.floor(mb * 1024 * 1024) or 0   -- 0 = no limit
end

function TranslationCache:_part(lang)
    local name = langFile(lang)
    local part = self.parts[name]
    if not part then
        part = newPartition(self.dir and (self.dir .. "/" .. name .. ".jsonl") or nil)
        self.parts[name] = part
    end
    return part, name
end

function TranslationCache:_ensureDir()
    if self.dir then
        mkdir(TranslationCache.getDir())
        mkdir(self.dir)
    end
end

-- The cached translation for `key` in language `lang`, or nil.
function TranslationCache:get(lang, key)
    local part, name = self:_part(lang)
    self.active = name
    return part:get(key)
end

-- Stores a translation (replacing an older one under the same key), then keeps
-- the cache within its size limit.
function TranslationCache:put(lang, key, text)
    if type(key) ~= "string" or type(text) ~= "string" or text == "" then return false end
    local part, name = self:_part(lang)
    self.active = name
    part:put(key, text, function() self:_ensureDir() end)
    self:enforceLimit()
    return true
end

-- Names (language codes) of the languages this book has cached translations for.
function TranslationCache:languages()
    local names, seen = {}, {}
    local function add(name) if not seen[name] then seen[name] = true; names[#names + 1] = name end end
    for name, part in pairs(self.parts) do
        if part.loaded and part.n > 0 then add(name) end
    end
    local lfs = self.dir and getLfs()
    if lfs then
        local ok, iter, state = pcall(lfs.dir, self.dir)
        if ok and iter then
            for file in iter, state do
                local name = file:match("^(.+)%.jsonl$")
                if name then add(name) end
            end
        end
    end
    table.sort(names)
    return names
end

-- { [language code] = number of cached translations } (loads each language file;
-- the ones not being read are released again).
function TranslationCache:countsByLanguage()
    local counts = {}
    for _, name in ipairs(self:languages()) do
        local part = self:_part(name)
        part:load()
        if part.n > 0 then counts[name] = part.n end
        if name ~= self.active then part:unload() end
    end
    return counts
end

function TranslationCache:count()
    local total = 0
    for _, n in pairs(self:countsByLanguage()) do total = total + n end
    return total
end

-- Removes every translation into `lang` (and only those): its file goes.
-- Returns how many entries that were.
function TranslationCache:clearLanguage(lang)
    local part, name = self:_part(lang)
    part:load()
    local removed = part.n
    part:unload()
    part.loaded = true               -- empty, and nothing to read back from disk
    if part.path then os.remove(part.path) end
    self:_removeDirIfEmpty()
    return removed
end

-- Removes everything cached for this book. Returns how many entries that were.
function TranslationCache:clear()
    local removed = 0
    for _, name in ipairs(self:languages()) do
        removed = removed + self:clearLanguage(name)
    end
    return removed
end

function TranslationCache:_removeDirIfEmpty()
    local lfs = self.dir and getLfs()
    if lfs and lfs.rmdir then pcall(lfs.rmdir, self.dir) end   -- fails (harmlessly) if not empty
end

-- All language files of all books: { path =, size =, mtime = }.
local function listPartitionFiles()
    local files = {}
    local lfs = getLfs()
    if not (lfs and lfs.attributes) then return files, false end
    local root = TranslationCache.getDir()
    local ok, iter, state = pcall(lfs.dir, root)
    if not (ok and iter) then return files, true end
    for book in iter, state do
        if book ~= "." and book ~= ".." then
            local book_dir = root .. "/" .. book
            local attr = lfs.attributes(book_dir)
            if attr and attr.mode == "directory" then
                local ok2, iter2, state2 = pcall(lfs.dir, book_dir)
                if ok2 and iter2 then
                    for file in iter2, state2 do
                        if file:find("%.jsonl$") then
                            local path = book_dir .. "/" .. file
                            local fa = lfs.attributes(path)
                            if fa and fa.mode == "file" then
                                files[#files + 1] = { path = path, dir = book_dir, size = fa.size or 0, mtime = fa.modification or 0 }
                            end
                        end
                    end
                end
            end
        end
    end
    return files, true
end

-- { files = language files, books = books, bytes = size on disk } of the cache of
-- all books.
function TranslationCache.stats()
    local files = listPartitionFiles()
    local books, nbooks, bytes = {}, 0, 0
    for _, f in ipairs(files) do
        bytes = bytes + f.size
        if not books[f.dir] then
            books[f.dir] = true
            nbooks = nbooks + 1
        end
    end
    return { files = #files, books = nbooks, bytes = bytes }
end

-- Bytes the cache of all books takes on disk.
function TranslationCache.totalBytes()
    local total = 0
    for _, f in ipairs((listPartitionFiles())) do total = total + f.size end
    return total
end

-- Brings the cache of all books back under the size limit. Returns the number of
-- language files deleted and the number of entries trimmed.
function TranslationCache:enforceLimit()
    local max = self.max_bytes
    if not max or max <= 0 then return 0, 0 end
    local goal = math.floor(max * EVICT_TO)

    -- Without a file listing (memory-only cache) only the open language counts.
    local files, can_list = listPartitionFiles()
    local active_part = self.active and self.parts[self.active]
    local active_path = active_part and active_part.path
    local total = 0
    for _, f in ipairs(files) do total = total + f.size end
    if not can_list or not self.dir then
        total = 0
        for _, part in pairs(self.parts) do total = total + part.bytes end
    end
    if total <= max then return 0, 0 end

    local files_removed, entries_removed = 0, 0

    -- 1. whole language files, least recently used first; never the one being read
    local candidates = {}
    for _, f in ipairs(files) do
        if f.path ~= active_path then candidates[#candidates + 1] = f end
    end
    table.sort(candidates, function(a, b) return a.mtime < b.mtime end)
    local lfs = getLfs()
    for _, f in ipairs(candidates) do
        if total <= goal then break end
        if os.remove(f.path) then
            total = total - f.size
            files_removed = files_removed + 1
            -- forget a loaded copy of it (another language of the open book)
            for name, part in pairs(self.parts) do
                if part.path == f.path then part:unload(); part.loaded = true end
            end
            if lfs and lfs.rmdir then pcall(lfs.rmdir, f.dir) end
        end
    end

    -- 2. the language being read: its oldest entries
    if total > goal and active_part then
        local on_disk = 0
        for _, f in ipairs(files) do if f.path == active_path then on_disk = f.size end end
        if not can_list or not self.dir then on_disk = active_part.bytes end
        local target = math.max(0, active_part.bytes - (total - goal))
        entries_removed = active_part:trimTo(target)
    end

    if files_removed > 0 or entries_removed > 0 then
        logger.info("splitread cache: over the limit, removed", files_removed, "language files and", entries_removed, "entries")
    end
    return files_removed, entries_removed
end

-- Deletes the cache of every book. `current` (an open cache) is emptied in memory
-- too. Returns how many files were removed.
function TranslationCache.clearAll(current)
    local removed = 0
    local lfs = getLfs()
    if lfs then
        local root = TranslationCache.getDir()
        local ok, iter, state = pcall(lfs.dir, root)
        if ok and iter then
            for name in iter, state do
                if name ~= "." and name ~= ".." then
                    local path = root .. "/" .. name
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "directory" then
                        local ok2, iter2, state2 = pcall(lfs.dir, path)
                        if ok2 and iter2 then
                            for file in iter2, state2 do
                                if file ~= "." and file ~= ".." and os.remove(path .. "/" .. file) then removed = removed + 1 end
                            end
                        end
                        if lfs.rmdir then pcall(lfs.rmdir, path) end
                    elseif name:find("%.jsonl") then
                        if os.remove(path) then removed = removed + 1 end
                    end
                end
            end
        end
    end
    if current then
        for _, part in pairs(current.parts) do
            part:unload()
            part.loaded = true
        end
    end
    return removed
end

return TranslationCache
