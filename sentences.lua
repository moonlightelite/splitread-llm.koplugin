-- Finding where sentences end, so that a sentence cut in two by a page break is
-- translated whole (see splitread:stitchPageText).
--
-- A sentence ends at ". ! ?" or at a full-width one (。！？), an ellipsis or the
-- end mark of other scripts, plus any closing quotes or brackets that follow it.
-- A terminator does NOT end a sentence when
--   * (ASCII ones) it is not followed by white space or the end: 3.14, e.g.x
--   * it follows an abbreviation or an initial: Mr. Smith, J. R. R. Tolkien, z. B.
--   * a lower case letter comes next: "Where?" she asked.
-- All of this is a heuristic that works on bytes and UTF-8 sequences; it needs no
-- locale support.

local Sentences = {}

-- Sentence-ending marks that are more than one byte long. `hard` ones end a
-- sentence even without white space after them (CJK text has none).
local TERMINATORS = {
    { "\227\128\130", true },  -- 。
    { "\239\188\129", true },  -- ！
    { "\239\188\159", true },  -- ？
    { "\226\128\188", true },  -- ‼
    { "\226\129\135", true },  -- ⁇
    { "\226\129\136", true },  -- ⁈
    { "\226\129\137", true },  -- ⁉
    { "\226\128\166", false }, -- …
    { "\216\159", false },     -- ؟ (Arabic question mark)
    { "\219\148", false },     -- ۔ (Urdu full stop)
    { "\224\165\164", false }, -- । (Devanagari danda)
    { "\224\165\165", false }, -- ॥
    { "\225\141\162", false }, -- ። (Ethiopic full stop)
    { "\214\137", false },     -- ։ (Armenian full stop)
}

-- Closing quotes and brackets that stay with the sentence they close.
local CLOSERS = {
    "\"", "'", ")", "]", "}",
    "\226\128\157", -- ”
    "\226\128\153", -- ’
    "\194\187",     -- »
    "\226\128\186", -- ›
    "\227\128\141", -- 」
    "\227\128\143", -- 』
    "\239\188\137", -- ）
    "\227\128\145", -- 】
    "\227\128\139", -- 》
    "\227\128\137", -- 〉
}

-- Closers that may be separated from the terminator by a space.
local SPACED_CLOSERS = { "\194\187", "\226\128\186" } -- » ›

-- Opening quotes, brackets and dashes: skipped when looking at what comes next.
local OPENERS = {
    "\"", "'", "(", "[", "{", "-",
    "\226\128\156", -- “
    "\226\128\152", -- ‘
    "\194\171",     -- «
    "\226\128\158", -- „
    "\226\128\154", -- ‚
    "\227\128\140", -- 「
    "\227\128\142", -- 『
    "\239\188\136", -- （
    "\226\128\148", -- —
    "\226\128\147", -- –
    "\194\191",     -- ¿
    "\194\161",     -- ¡
}

-- Abbreviations that never end a sentence (lower case, without the dot).
local ABBREVIATIONS = {}
for w in ([[mr mrs ms mx dr prof sr sra srta jr st mt vs fig vol ch sec eq cf resp approx gen col lt capt sgt
    hon rev messrs mme mlle hr fr bd nr bzw ggf evtl inkl vgl ca tel str dott ing arch avv sig]]):gmatch("%S+") do
    ABBREVIATIONS[w] = true
end

local function startsWith(s, i, prefix)
    return s:sub(i, i + #prefix - 1) == prefix
end

-- Length of the terminator at byte i (and whether it is a hard one), or nil.
local function terminatorAt(s, i)
    local c = s:byte(i)
    if c == nil then return nil end
    if c == 0x2E or c == 0x21 or c == 0x3F then return 1, false end -- . ! ?
    if c < 0xC0 then return nil end
    for _, t in ipairs(TERMINATORS) do
        if startsWith(s, i, t[1]) then return #t[1], t[2] end
    end
    return nil
end

local function listAt(list, s, i)
    for _, item in ipairs(list) do
        if startsWith(s, i, item) then return #item end
    end
    return nil
end

local function spaceLen(s, i)
    local c = s:byte(i)
    if c == nil then return nil end
    if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x0B or c == 0x0C then return 1 end
    if c == 0xC2 and s:byte(i + 1) == 0xA0 then return 2 end              -- no-break space
    if c == 0xE3 and s:byte(i + 1) == 0x80 and s:byte(i + 2) == 0x80 then return 3 end -- ideographic space
    if c == 0xE2 and s:byte(i + 1) == 0x80 then
        local d = s:byte(i + 2)
        if d and d >= 0x80 and d <= 0x8B then return 3 end                -- en/em/thin spaces
    end
    return nil
end

-- Position of the first character after white space and opening quotes.
local function skipSpacesAndOpeners(s, i)
    while true do
        local l = spaceLen(s, i) or listAt(OPENERS, s, i)
        if not l then return i end
        i = i + l
    end
end

-- Is the character at byte i a lower case letter? (Latin incl. Latin-1, Latin
-- Extended-A and Vietnamese, Greek, Cyrillic, Armenian.)
local function isLowerAt(s, i)
    local b1 = s:byte(i)
    if b1 == nil then return false end
    if b1 >= 0x61 and b1 <= 0x7A then return true end
    if b1 < 0xC2 then return false end
    local b2 = s:byte(i + 1)
    if not b2 then return false end
    if b1 <= 0xDF then
        local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
        if cp >= 0xDF and cp <= 0xFF then return cp ~= 0xF7 end          -- ß à-ÿ
        if cp >= 0x100 and cp <= 0x17F then                              -- Latin Extended-A
            if cp == 0x138 or cp == 0x149 or cp == 0x17F then return true end
            if cp == 0x178 then return false end
            if (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then return cp % 2 == 0 end
            return cp % 2 == 1
        end
        if cp >= 0x3AC and cp <= 0x3CE then return true end              -- Greek
        if cp >= 0x430 and cp <= 0x45F then return true end              -- Cyrillic
        if cp >= 0x561 and cp <= 0x587 then return true end              -- Armenian
        return false
    end
    if b1 == 0xE1 then
        local b3 = s:byte(i + 2)
        if b3 then
            local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            if cp >= 0x1E00 and cp <= 0x1EFF then return cp % 2 == 1 end -- Latin Extended Additional
        end
    end
    return false
end

-- Is the dot at byte i the end of an abbreviation or an initial?
local function isAbbreviationDot(s, i)
    local j = i - 1
    while j >= 1 and not spaceLen(s, j) do
        local c = s:byte(j)
        if c == 0x22 or c == 0x28 or c == 0x5B then break end   -- stop at " ( [
        j = j - 1
    end
    local token = s:sub(j + 1, i - 1)
    token = token:gsub("^[\"'(%[{]+", "")
    if token == "" then return false end
    local char_count = 0
    for _ in token:gmatch("[%z\1-\127\194-\244][\128-\191]*") do char_count = char_count + 1 end
    -- An initial (J. R. R. Tolkien, Ä. Müller): one Latin/Greek/Cyrillic letter.
    -- Not a one-character CJK or Hangul word, which may well end a sentence.
    if char_count == 1 and #token <= 2 and not token:find("^%d") then return true end
    local lower = token:lower()
    if ABBREVIATIONS[lower] then return true end
    if lower:find("%.") then                                             -- z.B.  e.g.  U.S.
        local all_short = true
        for part in lower:gmatch("[^%.]+") do
            if #part > 2 then all_short = false end
        end
        return all_short
    end
    return false
end

-- Does the run of terminators and closers at s[from..to_] end a sentence?
-- `following` is the text that comes after `s` (the next page), used only when
-- the run is the very end of `s`.
local function endsSentence(s, from, after, hard, following)
    local n = #s
    if not hard and after <= n and not spaceLen(s, after) then
        return false                                   -- 3.14  e.g.x  www.site.org
    end
    if s:byte(from) == 0x2E and after == from + 1 and isAbbreviationDot(s, from) then
        return false
    end
    local k = skipSpacesAndOpeners(s, after)
    if k <= n then
        return hard or not isLowerAt(s, k)
    end
    if not hard and following and following ~= "" then
        local f = skipSpacesAndOpeners(following, 1)
        if f <= #following and isLowerAt(following, f) then return false end
    end
    return true
end

-- Byte positions p such that s:sub(1, p) ends a sentence, in ascending order.
function Sentences.boundaries(s, following)
    local list = {}
    local n = #s
    local i = 1
    while i <= n do
        local tlen, hard = terminatorAt(s, i)
        if tlen then
            local j = i + tlen
            local any_hard = hard
            while true do
                local l2, h2 = terminatorAt(s, j)
                if l2 then
                    j = j + l2
                    any_hard = any_hard or h2
                else
                    local cl = listAt(CLOSERS, s, j)
                    if not cl then
                        -- French puts a space before the closing guillemet: « Où ? »
                        local sl = spaceLen(s, j)
                        local gl = sl and listAt(SPACED_CLOSERS, s, j + sl)
                        if not gl then break end
                        cl = sl + gl
                    end
                    j = j + cl
                end
            end
            if endsSentence(s, i, j, any_hard, following) then
                list[#list + 1] = j - 1
            end
            i = j
        else
            i = i + 1
        end
    end
    return list
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cuts `s` so that it is at most `max` bytes, on a character boundary and, when
-- possible, on a word boundary. `from_end` keeps the end of the text instead.
function Sentences.limit(s, max, from_end)
    if #s <= max then return s end
    local cut
    if from_end then
        cut = #s - max + 1
        while cut <= #s and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do cut = cut + 1 end
        local space = s:find("%s", cut)
        if space and space - cut < 40 then cut = space + 1 end
        return trim(s:sub(cut))
    end
    cut = max
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    local head = s:sub(1, cut)
    local space = head:match("^.*()%s")
    if space and cut - space < 40 then head = head:sub(1, space - 1) end
    return trim(head)
end

-- The unfinished last sentence of `text` (what follows its last sentence end), or
-- "" when `text` ends with a complete sentence. `following` is the text after it.
function Sentences.unfinishedTail(text, following)
    local b = Sentences.boundaries(text, following)
    local last = b[#b] or 0
    return trim(text:sub(last + 1))
end

-- The first sentence of `text` (up to and including its end mark), or nil if
-- `text` holds no complete sentence.
function Sentences.firstSentence(text, following)
    local b = Sentences.boundaries(text, following)
    if b[1] then return trim(text:sub(1, b[1])) end
    return nil
end

return Sentences
