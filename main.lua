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

local splitread = InputContainer:extend{
    name = "splitread",
    is_doc_only = true,
    panel_text = "splitread ready...",
    panel_height = 0,
    config = nil,
    is_initialized = false, 
    translation_cache = {},
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

    -- Per instance (a table on the class would be shared by every book opened
    -- in this session, showing book A's translation on book B's page).
    self.translation_cache = {}
    -- One stable function, so a pending run can be unscheduled when the user
    -- flips pages quickly (a request to a local LLM can take a while).
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

-- Byte position of the first capital letter: A-Z, or Latin-1 À-Þ (two bytes,
-- 0xC3 0x80-0x9E, minus the multiplication sign). Do not use a Lua set such as
-- [A-ZÄÖÜ] for this: a set matches single bytes, and bytes like 0x9C also sit
-- inside other characters (the last byte of “). Cutting the text there leaves
-- invalid UTF-8, which vLLM rejects with HTTP 400 "error parsing the body".
local function findFirstCapital(s)
    local first = s:find("[A-Z]")
    local from = 1
    while true do
        local p = s:find("\195[\128-\158]", from)
        if not p then break end
        if s:byte(p + 1) ~= 0x97 then
            if not first or p < first then first = p end
            break
        end
        from = p + 2
    end
    return first
end

-- Joins the unfinished sentence at the end of the previous page and the start
-- of the next one onto the current page, so every sentence is translated whole.
function splitread:stitchPageText(current_page, current)
    local prev_tail = ""
    if current_page > 1 then
        local prev = self:getTextForPage(current_page - 1)
        if prev and #prev > 0 then
            local last_dot = 0
            for i = #prev, 1, -1 do
                local c = prev:sub(i, i)
                if c == "." or c == "!" or c == "?" then
                    last_dot = i
                    break
                end
            end
            if last_dot > 0 and last_dot < #prev then
                prev_tail = prev:sub(last_dot + 1):gsub("^%s+", "")
            end
        end
    end

    local next_head = ""
    local next_text = self:getTextForPage(current_page + 1)
    if next_text and #next_text > 0 then
        local first_dot = 0
        for i = 1, #next_text do
            local c = next_text:sub(i, i)
            if c == "." or c == "!" or c == "?" then
                first_dot = i
                break
            end
        end
        if first_dot > 0 then
            next_head = next_text:sub(1, first_dot)
        end
    end

    local first_cap = findFirstCapital(current)
    local clean_current = current
    if first_cap and first_cap > 1 then
        local incomplete_start = current:sub(1, first_cap - 1):gsub("^%s+", "")
        clean_current = current:sub(first_cap)
        if #prev_tail > 0 then
            prev_tail = prev_tail .. incomplete_start
        end
    else
        prev_tail = ""
    end

    local last_dot = 0
    for i = #clean_current, 1, -1 do
        local c = clean_current:sub(i, i)
        if c == "." or c == "!" or c == "?" then
            last_dot = i
            break
        end
    end

    local incomplete_end = ""
    if last_dot > 0 and last_dot < #clean_current then
        incomplete_end = clean_current:sub(last_dot + 1):gsub("^%s+", "")
        clean_current = clean_current:sub(1, last_dot)
    end

    local parts = {}
    if #prev_tail > 0 then table.insert(parts, prev_tail) end
    if #clean_current > 0 then table.insert(parts, clean_current) end
    if #incomplete_end > 0 and #next_head > 0 then
        table.insert(parts, incomplete_end .. next_head)
    elseif #incomplete_end > 0 then
        table.insert(parts, incomplete_end)
    end

    local final_text = table.concat(parts, " ")
    return final_text
end

-- A page counts as "has text" when it holds at least this many non-space chars.
local MIN_TEXT_CHARS = 8
local IMAGE_JPEG_QUALITY = 85

-- Key for the translation cache. Everything that changes the result is part of
-- it, so editing the language, provider or system prompt never shows a stale one.
function splitread:getCacheKey(page, kind)
    local c = self.config
    local provider = c.provider or "google"
    local parts = { self:getBookKey() or "", provider, c.source_lang, c.target_lang, kind, page }
    if provider == "local" then
        table.insert(parts, c.local_url)
        table.insert(parts, c.local_model)
        table.insert(parts, c.local_system_prompt)
        table.insert(parts, c.image_max_side)
    end
    for i, v in ipairs(parts) do parts[i] = tostring(v) end
    return table.concat(parts, "\31")
end

-- Shows the cached translation for `key`, if any. Returns true when it did.
function splitread:showCachedTranslation(key, force)
    if force then
        self.translation_cache[key] = nil
        return false
    end
    local cached = self.translation_cache[key]
    if not cached then return false end
    self.panel_text = cached
    self:refreshPanel()
    return true
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
    else
        self.panel_text = translated or "Empty translation."
        self.translation_cache[key] = self.panel_text
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
function splitread:translateCurrentPage(force)
    local provider = self.config.provider or "google"
    local mode = self.config.page_input or "auto"

    if not Translator:isNetworkAvailable(provider, self.config.local_url) then
        self.panel_text = "No internet connection."
        self:refreshPanel()
        return
    end

    local current_page = self.ui:getCurrentPage()

    local current
    if mode ~= "image" then
        current = self:getTextForPage(current_page)
    end

    -- Page image (OCR) instead of page text: always in "image" mode, and in
    -- "auto" mode when the page has no text (scanned PDF, comic, ...) and the
    -- provider can read images.
    local compact = current and current:gsub("%s", "") or ""
    local use_image = mode == "image"
        or (mode == "auto" and provider == "local" and #compact < MIN_TEXT_CHARS)

    if use_image then
        if provider ~= "local" then
            self.panel_text = "Page images can only be read by the Local LLM provider. "
                .. "Choose it in Settings > Provider."
            self:refreshPanel()
            return
        end
        local key = self:getCacheKey(current_page, "image")
        if self:showCachedTranslation(key, force) then return end
        self.panel_text = "Preparing the page image..."
        self:refreshPanel()
        local image, err = self:getPageImage(current_page)
        if not image then
            self.panel_text = "Error: " .. tostring(err)
            self:refreshPanel()
            return
        end
        self:runTranslation(key, nil, image)
        return
    end

    if not current or #current == 0 then
        self.panel_text = "No text found. (Image-only pages can be read by the Local LLM provider.)"
        self:refreshPanel()
        return
    end

    local final_text = self:stitchPageText(current_page, current)
    if #final_text == 0 then
        self.panel_text = "No complete sentences found."
        self:refreshPanel()
        return
    end

    local key = self:getCacheKey(current_page, "text")
    if self:showCachedTranslation(key, force) then return end
    self:runTranslation(key, final_text, nil)
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

function splitread:showSettingsDialog()
    if not self.config then
        self.config = Config:load()
    end
    UI:showSettingsDialog(self.config, Config,
        function()
            self:refreshPanel()
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
        },
    }
end

return splitread
