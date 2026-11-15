local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Screen = require("device").screen
local Event = require("ui/event")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")

local Config = require("config")
local Translator = require("translator")
local UI = require("ui_splitread")
local TranslationCache = require("translation_cache")
local Sentences = require("sentences")

local splitread = InputContainer:extend{
    name = "splitread",
    is_doc_only = true,
    panel_text = "splitread ready...",
    panel_height = 0,
    config = nil,
    is_initialized = false, 
}

function splitread:init()
    self.ui.menu:registerToMainMenu(self)
    local ok, config = pcall(function() return Config:load() end)
    if ok and config then
        self.config = config
    else
        self.config = {}
        for k, v in pairs(Config.defaults) do self.config[k] = v end
    end
    self.panel_height = math.floor(Screen:getHeight() * self.config.panel_height_ratio)

    -- The translation cache of the open book, loaded on first use
    -- (see getTranslationCache). Per instance, never shared between books.
    self.tcache = nil
    -- One stable function, so a pending run can be unscheduled when the user
    -- flips pages quickly (a request to a local LLM can take a while).
    self.prefetch_task = function() self:prefetchStep() end
    self.prefetch_poll_task = function() self:prefetchPoll() end
    self.translate_task = function()
        -- The book may have been disabled while this was pending.
        if self:isEnabledForBook() then self:translateCurrentPage() end
    end

    local tap_size = Screen:scaleByDPI(60)
    local tap_margin = Screen:scaleByDPI(16)
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{
                x = Screen:getWidth() - tap_size - tap_margin,
                y = Screen:getHeight() - tap_size - tap_margin,
                w = tap_size,
                h = tap_size,
            },
        },
    }
    logger.info("splitread: init, panel_height:", self.panel_height)
end

function splitread:onTap(_, ges)
    if not self:isEnabledForBook() then return end
    logger.info("splitread: TAP DETECTED at", ges.pos.x, ges.pos.y)
    self:showSettingsDialog()
    return true
end

function splitread:getFooterHeight()
    if self.view and self.view.footer and self.view.footer_visible then
        return self.view.footer:getHeight()
    end
    return 0
end

function splitread:getBookKey()
    if self.ui and self.ui.document and self.ui.document.file then
        return "book_" .. self.ui.document.file:gsub("[^%w]", "_")
    end
    return nil
end

function splitread:isEnabledForBook()
    local key = self:getBookKey()
    if not key then return false end
    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/splitread.lua")
    return s:isTrue(key)
end

function splitread:setEnabledForBook(enabled)
    local key = self:getBookKey()
    if not key then return end
    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/splitread.lua")
    s:saveSetting(key, enabled)
    s:flush()
    logger.info("splitread: book enabled state saved:", enabled, "key:", key)
end

function splitread:onReaderReady()
    logger.info("splitread: onReaderReady called, enabled:", self:isEnabledForBook(), "initialized:", self.is_initialized)
    if not self:isEnabledForBook() then
        logger.info("splitread: disabled for this book")
        return
    end
    if self.is_initialized then
        logger.info("splitread: already initialized, skipping")
        return
    end
    self.is_initialized = true
    logger.info("splitread: initializing...")
    self.panel_text = "splitread ready! Tap ⚙ to configure."
    self:shrinkReadingArea()
    UIManager:scheduleIn(0.5, function() self:refreshPanel() end)
    local orig_paintTo = self.view.paintTo
    self.view.paintTo = function(view, bb, x, y)
        orig_paintTo(view, bb, x, y)
        self:refreshPanel()
    end
end

function splitread:shrinkReadingArea()
    local footer_h = self:getFooterHeight()
    local screen_h = Screen:getHeight()
    local new_h = screen_h - self.panel_height - footer_h
    if self.ui.paging then
        -- For paged documents (PDF, CBZ, DjVu) ReaderView already subtracts
        -- the footer from the visible area itself.
        new_h = new_h + footer_h
    end
    self.view.dimen.h = new_h
    self.ui.dimen.h = new_h
    if self.ui.rolling then
        -- Page margins only exist for reflowable documents (CreDocument).
        local margins = self.ui.document:getPageMargins()
        self.ui:handleEvent(Event:new("SetPageMargins", {
            margins.left,
            margins.top,
            margins.right,
            2,
        }))
        logger.info("splitread: set bottom margin to 2")
    end
    self.ui:handleEvent(Event:new("SetDimensions", self.ui.dimen))
    if self.ui.paging then
        -- Re-zoom and redraw the page for the smaller area.
        self.ui:handleEvent(Event:new("RedrawCurrentPage"))
    end
end

function splitread:flattenText(t)
    if type(t) == "string" then return t end
    local words = {}
    for _, item in ipairs(t) do
        if type(item) == "table" and item.word then
            table.insert(words, item.word)
        elseif type(item) == "string" then
            table.insert(words, item)
        end
    end
    return table.concat(words, " ")
end

-- Words of a paged document page, as returned by getPageTextBoxes(): a list of
-- lines, each a list of word boxes ({ word = "...", x0 = ..., ... }).
function splitread:flattenTextBoxes(boxes)
    local lines = {}
    for _, line in ipairs(boxes) do
        local words = {}
        if type(line) == "table" then
            for _, box in ipairs(line) do
                if type(box) == "table" and box.word then
                    table.insert(words, box.word)
                end
            end
        end
        if #words > 0 then
            table.insert(lines, table.concat(words, " "))
        end
    end
    return table.concat(lines, " ")
end

function splitread:getTextForPage(page)
    local doc = self.ui.document
    local ok, text = pcall(function()
        if self.ui.paging then
            -- PDF/DjVu/CBZ: use the text layer if there is one.
            return self:flattenTextBoxes(doc:getPageTextBoxes(page) or {})
        end
        local pos0 = doc:getPageXPointer(page)
        local pos1 = doc:getPageXPointer(page + 1)
        return doc:getTextFromXPointers(pos0, pos1, false)
    end)
    if not ok or not text then return nil end
    return self:flattenText(text)
end

-- How far a sentence is followed across page breaks (characters of text).
local PREV_TAIL_MAX = 500        -- start of a sentence that began on the previous page
local READ_AHEAD_MAX = 900       -- end of a sentence that continues on the next pages
local READ_AHEAD_PAGES = 3       -- ... but never further than this many pages

-- Text for the translation of `current_page`, whose own text is `current`.
-- A sentence cut in two by a page break is translated whole:
--   * when the page ends in the middle of a sentence, the rest of it is read from
--     the following page(s), up to the real end of the sentence;
--   * when the page begins with the end of a sentence that started on the
--     previous page, the beginning of that sentence is put in front.
-- Where a sentence ends is decided by sentences.lua (it knows full-width CJK
-- marks, closing quotes, abbreviations, ...).
function splitread:stitchPageText(current_page, current)
    current = current:gsub("^%s+", ""):gsub("%s+$", "")

    local prev_tail = ""
    if current_page > 1 then
        local prev = self:getTextForPage(current_page - 1)
        if prev and #prev > 0 then
            prev_tail = Sentences.limit(Sentences.unfinishedTail(prev, current), PREV_TAIL_MAX, true)
        end
    end

    local next_head = ""
    local next_text = self:getTextForPage(current_page + 1)
    if Sentences.unfinishedTail(current, next_text) ~= "" then
        -- The page ends mid-sentence: read on until the sentence is complete.
        local ahead = ""
        local page = current_page + 1
        local text = next_text
        for _ = 1, READ_AHEAD_PAGES do
            if not text or #text == 0 then break end
            ahead = (ahead == "" and "" or (ahead .. " ")) .. text
            local following = self:getTextForPage(page + 1)
            local sentence = Sentences.firstSentence(ahead, following)
            if sentence then
                next_head = sentence
                break
            end
            if #ahead >= READ_AHEAD_MAX then break end
            page = page + 1
            text = following
        end
        if next_head == "" and ahead ~= "" then
            -- No sentence end in sight (a very long sentence, or a page without
            -- punctuation): take what there is, up to the limit.
            next_head = ahead
        end
        next_head = Sentences.limit(next_head, READ_AHEAD_MAX)
    end

    local parts = {}
    if prev_tail ~= "" then table.insert(parts, prev_tail) end
    if current ~= "" then table.insert(parts, current) end
    if next_head ~= "" then table.insert(parts, next_head) end
    return table.concat(parts, " ")
end

-- A page counts as "has text" when it holds at least this many non-space chars.
local MIN_TEXT_CHARS = 8
local IMAGE_JPEG_QUALITY = 85

local KEY_SEP = "\31"

-- The cache of the open book (translation_cache.lua): kept on disk, so it
-- survives closing the book. Falls back to a memory-only cache if the file
-- cannot be used.
function splitread:getTranslationCache()
    if not self.tcache then
        local file = self.ui and self.ui.document and self.ui.document.file
        local ok, cache = pcall(TranslationCache.open, file, self.config.cache_max_mb)
        if not ok or not cache then
            logger.warn("splitread: translation cache unavailable:", tostring(cache))
            cache = TranslationCache.open(nil, self.config.cache_max_mb)
        end
        self.tcache = cache
    end
    self.tcache:setMaxMB(self.config.cache_max_mb)   -- the limit may have been changed in the settings
    return self.tcache
end

-- First part of every cache key: everything about the settings that changes the
-- result. The TARGET language is in it, so a page translated into Simplified
-- Chinese and into Traditional Chinese are two separate entries (and so are
-- two providers, two source languages, two local models or system prompts).
function splitread:getCachePrefix(kind)
    local c = self.config
    local provider = c.provider or "google"
    local parts = { kind, provider, tostring(c.source_lang), tostring(c.target_lang) }
    if provider == "local" then
        -- Without a configured model the server picks one: tell servers apart then.
        local model = c.local_model or ""
        if model == "" then model = "auto@" .. tostring(c.local_url) end
        table.insert(parts, TranslationCache.hash(model .. "\0" .. tostring(c.local_system_prompt)))
    end
    return table.concat(parts, KEY_SEP)
end

-- Text translations are keyed by the text itself, not by the page number:
-- changing the font size or the panel size re-flows an EPUB, and "page 5" is
-- then different text.
function splitread:getTextCacheKey(text)
    return self:getCachePrefix("t") .. KEY_SEP .. TranslationCache.hash(text)
end

-- Page images have no text to key on. A PDF/CBZ page keeps its number; the size
-- of the reading area is part of the key because it decides what the picture
-- shows for an EPUB.
function splitread:getImageCacheKey(page)
    local dimen = self.ui.dimen or {}
    return table.concat({
        self:getCachePrefix("i"), tostring(page),
        tostring(dimen.w) .. "x" .. tostring(dimen.h), tostring(self.config.image_max_side),
    }, KEY_SEP)
end

-- Shows the cached translation for `key`, if any. Returns true when it did.
-- `force` ("Translate this page now") ignores the cache; the new result then
-- replaces the old entry.
function splitread:showCachedTranslation(key, force)
    if force then return false end
    local cached = self:getTranslationCache():get(self.config.target_lang, key)
    if not cached then return false end
    self.panel_text = cached
    self:refreshPanel()
    self:schedulePrefetch()
    return true
end

-- False (after telling the user in the panel) when there is no connection to
-- the translation service.
function splitread:hasConnection()
    if Translator:isNetworkAvailable(self.config.provider or "google", self.config.local_url) then
        return true
    end
    self.panel_text = "No internet connection."
    self:refreshPanel()
    return false
end

-- Sends `text` or `image` to the configured provider and shows the result.
function splitread:runTranslation(key, text, image)
    self.panel_text = image and "Reading the page image and translating..." or "Translating..."
    self:refreshPanel()

    local translated, err = Translator:translate(
        text,
        self.config.source_lang,
        self.config.target_lang,
        self.config.provider,
        {
            config = self.config,
            image = image,
            source_name = UI:getLanguageName(self.config.source_lang),
            target_name = UI:getLanguageName(self.config.target_lang),
        }
    )

    if err then
        self.panel_text = "Error: " .. err
    elseif translated and translated ~= "" then
        self.panel_text = translated
        self:getTranslationCache():put(self.config.target_lang, key, translated)
        self:schedulePrefetch()
    else
        self.panel_text = "Empty translation."
    end

    self:refreshPanel()
end

-- The current page as a bitmap: returns a Blitbuffer and whether the caller
-- owns it (and must free it). Paged documents are rendered at a resolution
-- suited to OCR; reflowable ones (an EPUB made of images, ...) are cropped
-- from what is on screen.
function splitread:capturePageBB(page)
    if self.ui.paging then
        local ok, tile = pcall(function()
            local doc = self.ui.document
            local native = doc:getNativePageDimensions(page)
            local max_side = tonumber(self.config.image_max_side) or 1600
            local zoom = max_side / math.max(native.w, native.h)
            return doc:renderPage(page, nil, zoom, 0, 1.0, 1.0)
        end)
        if ok and tile and tile.bb then
            return tile.bb, false -- owned by KOReader's page cache: never free it
        end
        logger.info("splitread: renderPage failed, capturing the screen instead:", tostring(tile))
    end

    local width = Screen:getWidth()
    local height = Screen:getHeight() - self.panel_height - self:getFooterHeight()
    local crop = Blitbuffer.new(width, height, Screen.bb:getType())
    crop:blitFrom(Screen.bb, 0, 0, 0, 0, width, height)
    return crop, true
end

-- The current page as { data = <base64>, mime = <type> }, or nil, error.
function splitread:getPageImage(page)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local mime = require("mime")

    local ok_bb, bb, owned = pcall(function() return self:capturePageBB(page) end)
    if not ok_bb or not bb then
        return nil, "Could not capture the page image."
    end

    local dir = DataStorage:getDataDir() .. "/cache"
    lfs.mkdir(dir) -- harmless if it already exists
    local path = dir .. "/splitread_page.tmp"

    local mime_type
    if pcall(function() bb:writeJPG(path, IMAGE_JPEG_QUALITY) end) then
        mime_type = "image/jpeg"
    elseif pcall(function() bb:writePNG(path) end) then
        mime_type = "image/png"
    end
    if owned then bb:free() end
    if not mime_type then
        return nil, "Could not encode the page image."
    end

    local f = io.open(path, "rb")
    local data = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    if not data or #data == 0 then
        return nil, "Could not read back the page image."
    end

    logger.info("splitread: page image", mime_type, #data, "bytes")
    return { data = (mime.b64(data)), mime = mime_type }
end

-- `force` skips the cache (used by "Translate this page now").
-- Decides what has to be translated for `page`: its (stitched) text or its
-- image. Returns a plan { kind = "text"|"image", page =, key =, text = }, or nil
-- and the message to show instead.
function splitread:planPage(page)
    local provider = self.config.provider or "google"
    local mode = self.config.page_input or "auto"

    local current
    if mode ~= "image" then
        current = self:getTextForPage(page)
    end

    -- Page image (OCR) instead of page text: always in "image" mode, and in
    -- "auto" mode when the page has no text (scanned PDF, comic, ...) and the
    -- provider can read images.
    local compact = current and current:gsub("%s", "") or ""
    local use_image = mode == "image"
        or (mode == "auto" and provider == "local" and #compact < MIN_TEXT_CHARS)

    if use_image then
        if provider ~= "local" then
            return nil, "Page images can only be read by the Local LLM provider. "
                .. "Choose it in Settings > Provider."
        end
        return { kind = "image", page = page, key = self:getImageCacheKey(page) }
    end

    if not current or #current == 0 then
        return nil, "No text found. (Image-only pages can be read by the Local LLM provider.)"
    end

    local final_text = self:stitchPageText(page, current)
    if #final_text == 0 then
        return nil, "No complete sentences found."
    end
    return { kind = "text", page = page, text = final_text, key = self:getTextCacheKey(final_text) }
end

-- `force` skips the cache (used by "Translate this page now").
function splitread:translateCurrentPage(force)
    local page = self.ui:getCurrentPage()
    local plan, message = self:planPage(page)
    if not plan then
        self.panel_text = message
        self:refreshPanel()
        return
    end

    -- A cached translation needs no connection: the network is only checked
    -- once a request has to be made.
    if self:showCachedTranslation(plan.key, force) then return end
    -- The page is being translated in the background already: wait for that.
    if not force and self:waitForPrefetch(plan.key) then return end
    if not self:hasConnection() then return end

    if plan.kind == "image" then
        self.panel_text = "Preparing the page image..."
        self:refreshPanel()
        local image, err = self:getPageImage(page)
        if not image then
            self.panel_text = "Error: " .. tostring(err)
            self:refreshPanel()
            return
        end
        self:runTranslation(plan.key, nil, image)
    else
        self:runTranslation(plan.key, plan.text, nil)
    end
end

------------------------------------------------------------------------------
-- Pre-translation: the next pages are translated in the background, so that
-- turning the page finds the translation in the cache.
--
-- The request runs in a separate process (ffi/util.runInSubProcess), so the
-- reader stays responsive however long the server takes (a local model may need
-- a minute per page). One page at a time; the answer comes back through a pipe,
-- is polled for, and goes into the cache.
------------------------------------------------------------------------------

local PREFETCH_DELAY = 1.0          -- seconds after a translation before the next page is started
local PREFETCH_POLL = 0.4           -- how often a running request is checked on
local PREFETCH_PAUSE = 60           -- seconds without trying again after a failure
local PREFETCH_MAX_PAYLOAD = 48 * 1024   -- stays below the 64 KB buffer of a pipe

function splitread:getPrefetchCount()
    local n = tonumber(self.config.prefetch_pages) or 0
    return math.max(0, math.min(math.floor(n), 20))
end

function splitread:getLastPage()
    local ok, n = pcall(function()
        local doc = self.ui.document
        return doc.getPageCount and doc:getPageCount()
    end)
    return ok and tonumber(n) or nil
end

-- (Re)starts the countdown to the next background translation.
function splitread:schedulePrefetch()
    UIManager:unschedule(self.prefetch_task)
    if self.closed or self:getPrefetchCount() == 0 or not self.config.auto_translate then return end
    UIManager:scheduleIn(PREFETCH_DELAY, self.prefetch_task)
end

-- Starts the translation of the first page ahead that is not in the cache yet.
function splitread:prefetchStep()
    if self.closed or self.prefetch_job then return end
    local count = self:getPrefetchCount()
    if count == 0 or not self.config.auto_translate or not self:isEnabledForBook() then return end

    local pause = (self.prefetch_pause_until or 0) - os.time()
    if pause > 0 then
        UIManager:scheduleIn(pause + 1, self.prefetch_task)
        return
    end
    if not Translator:isNetworkAvailable(self.config.provider or "google", self.config.local_url) then return end

    local cache = self:getTranslationCache()
    local lang = self.config.target_lang
    local first = self.ui:getCurrentPage()
    local last = self:getLastPage() or math.huge
    for page = first + 1, math.min(first + count, last) do
        local plan = self:planPage(page)
        -- (the picture of a page is only available for PDF/CBZ/DjVu; an EPUB page
        -- cannot be rendered while it is not on the screen)
        if plan and (plan.kind == "text" or self.ui.paging) and not cache:get(lang, plan.key) then
            self:startPrefetchJob(plan)
            return
        end
    end
end

function splitread:startPrefetchJob(plan)
    local image
    if plan.kind == "image" then
        local img, err = self:getPageImage(plan.page)
        if not img then
            logger.warn("splitread: pre-translation: no page image:", tostring(err))
            self.prefetch_pause_until = os.time() + PREFETCH_PAUSE
            return
        end
        image = img
    end

    local cfg = self.config
    local source, target, provider = cfg.source_lang, cfg.target_lang, cfg.provider
    local opts = {
        config = cfg,
        image = image,
        source_name = UI:getLanguageName(source),
        target_name = UI:getLanguageName(target),
    }
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, translated, err = pcall(Translator.translate, Translator, plan.text, source, target, provider, opts)
        local payload
        if ok and type(translated) == "string" and translated ~= "" then
            payload = "OK\n" .. translated
        else
            payload = "ERR\n" .. tostring(ok and err or translated)
        end
        ffiutil.writeToFD(write_fd, payload:sub(1, PREFETCH_MAX_PAYLOAD), true)
    end, true)
    if not pid then
        logger.warn("splitread: pre-translation: could not start a process:", tostring(fd))
        self.prefetch_pause_until = os.time() + PREFETCH_PAUSE
        return
    end

    local timeout = tonumber(cfg.local_timeout) or 180
    self.prefetch_job = { pid = pid, fd = fd, key = plan.key, lang = target, page = plan.page, deadline = os.time() + timeout + 20 }
    logger.info("splitread: pre-translating page", plan.page)
    UIManager:scheduleIn(PREFETCH_POLL, self.prefetch_poll_task)
end

-- Checks on the running request; stores the answer in the cache when it is done.
function splitread:prefetchPoll()
    local job = self.prefetch_job
    if not job then return end
    local ffiutil = require("ffi/util")
    if not job.killed and os.time() > job.deadline then
        ffiutil.terminateSubProcess(job.pid)
        job.killed = true
    end
    if not ffiutil.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(PREFETCH_POLL, self.prefetch_poll_task)
        return
    end

    local data = ffiutil.readAllFromFD(job.fd)
    self.prefetch_job = nil
    if self.closed or job.killed then return end   -- stopped on purpose: drop the answer

    local status, body = (data or ""):match("^(%u+)\n(.*)$")
    if status == "OK" and body and body ~= "" then
        -- stored under the language it was asked for, even if the setting changed meanwhile
        self:getTranslationCache():put(job.lang, job.key, body)
        if self.waiting_key == job.key then
            self.waiting_key = nil
            self.panel_text = body
            self:refreshPanel()
        end
        self:schedulePrefetch()
    else
        logger.warn("splitread: pre-translation failed:", status == "ERR" and body or "no answer")
        self.prefetch_pause_until = os.time() + PREFETCH_PAUSE
        if self.waiting_key == job.key then
            -- the user is waiting for this page: ask again in the foreground,
            -- which also shows the error
            self.waiting_key = nil
            self:translateCurrentPage()
        end
    end
end

-- When the page the user turned to is being translated right now, show
-- "Translating..." and let the poll deliver the result. Returns true when it does.
function splitread:waitForPrefetch(key)
    local job = self.prefetch_job
    if not job or job.key ~= key or job.killed then return false end
    self.waiting_key = key
    self.panel_text = "Translating..."
    self:refreshPanel()
    return true
end

-- Stops pre-translating (book closed or disabled). A running request is killed;
-- the poll keeps going until the process is gone, so that it is collected.
function splitread:cancelPrefetch()
    UIManager:unschedule(self.prefetch_task)
    self.waiting_key = nil
    local job = self.prefetch_job
    if job and not job.killed then
        pcall(function() require("ffi/util").terminateSubProcess(job.pid) end)
        job.killed = true
    end
end

function splitread:onCloseDocument()
    self.closed = true
    self:cancelPrefetch()
end

function splitread:scheduleTranslation()
    UIManager:unschedule(self.translate_task)
    UIManager:scheduleIn(0.5, self.translate_task)
end

function splitread:onPageUpdate(pageno)
    if not self:isEnabledForBook() then return end
    if not self.config.auto_translate then return end
    self:scheduleTranslation()
end

function splitread:onPosUpdate(pos, pageno)
    if not self:isEnabledForBook() then return end
    if not self.config.auto_translate then return end
    self:scheduleTranslation()
end

function splitread:getPanelGearRegion()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local footer_h = self:getFooterHeight()
    local icon_size = Screen:scaleByDPI(32)
    local margin = Screen:scaleByDPI(16)
    return {
        x = screen_w - icon_size - margin,
        y = screen_h - footer_h - icon_size - margin,
        w = icon_size,
        h = icon_size,
    }
end

-- Changes whenever a setting that alters the translation changes (the page
-- itself aside): language, provider, model, system prompt, page input.
function splitread:getSettingsSignature()
    return table.concat({ self:getCachePrefix("t"), tostring(self.config.page_input),
        tostring(self.config.image_max_side) }, KEY_SEP)
end

function splitread:showSettingsDialog()
    if not self.config then
        self.config = Config:load()
    end
    local signature = self:getSettingsSignature()
    UI.translation_cache = self:getTranslationCache()   -- for "Translation cache..."
    UI:showSettingsDialog(self.config, Config,
        function()
            -- The settings were closed.
            self:refreshPanel()
            self:schedulePrefetch()   -- the number of pages ahead may have changed
            local now = self:getSettingsSignature()
            if now == signature then return end
            signature = now
            -- The panel still shows a translation made with the old settings
            -- (e.g. Simplified Chinese after switching to Traditional).
            if self.config.auto_translate then
                UIManager:scheduleIn(0.3, function()
                    if self:isEnabledForBook() then self:translateCurrentPage() end
                end)
            else
                -- No request without being asked, but do not keep showing a
                -- translation that no longer matches the settings.
                self.panel_text = "Settings changed. Open Settings > Translate this page now."
                self:refreshPanel()
            end
        end,
        function(new_ratio)
        end,
        function()
            -- Let the dialog close and the page repaint before a slow request.
            UIManager:scheduleIn(0.3, function()
                if self:isEnabledForBook() then self:translateCurrentPage(true) end
            end)
        end
    )
end

function splitread:refreshPanel()

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local footer_h = self:getFooterHeight()
    local panel_y = screen_h - self.panel_height - footer_h
    local padding = 20

    local ok, face = pcall(function()
        return Font:getFace("cfont", self.config.font_size or 14)
    end)
    if not ok or not face then
        face = Font:getFace("cfont", 14)
    end

    local frame = FrameContainer:new{
        width = screen_w,
        height = self.panel_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = padding,
        TextBoxWidget:new{
            text = self.panel_text,
            face = face,
            width = screen_w - (padding * 2),
            height = self.panel_height - (padding * 2) - 20,
            justified = true,
        }
    }
    frame:paintTo(Screen.bb, 0, panel_y)
    Screen.bb:paintRect(0, panel_y, screen_w, 1, Blitbuffer.COLOR_BLACK)

    local gear = self:getPanelGearRegion()
    local gear_widget = TextWidget:new{
        text = "⚙",
        face = Font:getFace("cfont", Screen:scaleByDPI(18)),
    }
    gear_widget:paintTo(Screen.bb, gear.x, gear.y)

    Screen:refreshUI(0, panel_y, screen_w, self.panel_height)
    logger.info("splitread: painted at y:", panel_y)
end

function splitread:addToMainMenu(menu_items)
    menu_items.splitread = {
        text = "splitread",
        sub_item_table = {
            {
                text_func = function()
                    return self:isEnabledForBook()
                        and "Disable for this book"
                        or "Enable for this book"
                end,
                callback = function()
                    local enabled = self:isEnabledForBook()
                    self:setEnabledForBook(not enabled)
                    if not enabled then
                        -- enabling
                        self.is_initialized = false  
                        self:onReaderReady()       
                    else
                        -- disabling — restore viewport
                        self:cancelPrefetch()
                        self.view.dimen.h = Screen:getHeight()
                        self.ui.dimen.h = Screen:getHeight()
                        self.ui:handleEvent(Event:new("SetDimensions", self.ui.dimen))
                        if self.ui.paging then
                            -- Re-zoom the page to the full screen again.
                            self.ui:handleEvent(Event:new("RedrawCurrentPage"))
                        end
                        Screen.bb:paintRect(0, Screen:getHeight() - self.panel_height,
                            Screen:getWidth(), self.panel_height, Blitbuffer.COLOR_WHITE)
                        Screen:refreshUI(0, Screen:getHeight() - self.panel_height,
                            Screen:getWidth(), self.panel_height)
                    end
                end,
            },
            {
                text = "Settings",
                callback = function()
                    self:showSettingsDialog()
                end,
            },
            {
                text = "Clear all translation cache...",
                callback = function()
                    -- a background request would only refill it
                    self:cancelPrefetch()
                    UI:confirmClear("all", self:getTranslationCache(), function() self:schedulePrefetch() end)
                end,
            },
        },
    }
end

return splitread
