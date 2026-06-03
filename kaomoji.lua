-- 万象家族 lua，颜文字输入模块
-- 采用 txt 维护数据，支持词典补全与 userdb 持久化缓存
-- 默认触发形式为 /kmj[pinyin]
-- 配置示例：
-- kaomoji:
--   db_name: "lua/kaomoji"  # 可选，缓存数据库名称/路径，默认值为 "lua/kaomoji"
--   kaomoji_key: "/kmj"     # 可选，触发前缀
--   files:                  # 可选，自定义数据文件列表
--     - lua/data/kaomoji.txt

local wanxiang = require("wanxiang/wanxiang")
local userdb = require("wanxiang/userdb")

local DEFAULT_KEY = "/kmj"
local DEFAULT_DB_NAME = "lua/kaomoji"
local DEFAULT_MAX_CANDIDATES = 80
local DEFAULT_DATA_FILES = {
    "lua/data/kaomoji.txt",
    "lua/data/kaomoji_user.txt",
}
local DEFAULT_DICT_PATHS = {
    "dicts/jichu.dict.yaml",
    "dicts/zi.dict.yaml",
    "dicts/diming.dict.yaml",
    "dicts/duoyin.dict.yaml",
    "dicts/lianxiang.dict.yaml",
    "dicts/shici.dict.yaml",
    "dicts/huaxue.dict.yaml",
    "dicts/yaopin.dict.yaml",
    "dicts/yixue.dict.yaml",
    "dicts/cn&en.dict.yaml",
}
local BOM = string.char(239, 187, 191)
local TAB = "\t"
local ENTRY_KEY_PREFIX = "entry/"

local TONE_MAP = {
    ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
    ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
    ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
    ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
    ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
    ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v", ["ü"] = "v",
    ["ń"] = "n", ["ň"] = "n", ["ǹ"] = "n",
    ["ḿ"] = "m",
}

local META_KEY = {
    version = "wanxiang_version",
    files_sig = "files_signature",
    dict_sig = "dict_signature",
}

local kaomoji = {
    files_signature = nil,
    dict_signature = nil,
    entries = {},
    db_name = nil,
    db = nil,
    db_mode = nil,
}

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function strip_bom(text)
    if not text then return "" end
    return text:gsub("^" .. BOM, "")
end

local function is_absolute_path(path)
    if not path then return false end
    return path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^[A-Za-z]:[\\/]")
end

local function close_file(file, close_fn)
    if close_fn then
        close_fn()
    elseif file then
        file:close()
    end
end

local function open_data_file(path, mode)
    if not path or path == "" then return nil end
    if is_absolute_path(path) then
        return io.open(path, mode or "r")
    end
    return wanxiang.load_file_with_fallback(path, mode)
end

local function get_configured_files(config)
    local files = {}
    local list = config:get_list("kaomoji/files")
    if list then
        for i = 0, list.size - 1 do
            local item = list:get_value_at(i)
            local path = item and trim(item.value) or ""
            if path ~= "" then
                table.insert(files, path)
            end
        end
    end
    return #files > 0 and files or DEFAULT_DATA_FILES
end

local function get_dict_files()
    local files = {}
    for _, path in ipairs(DEFAULT_DICT_PATHS) do
        if wanxiang.get_filename_with_fallback(path) then
            table.insert(files, path)
        end
    end
    return files
end

-- 轻量文件指纹：文件内容变化时才重新建立索引
local function generate_files_signature(paths)
    local sig_parts = {}
    for _, path in ipairs(paths) do
        local file, close_fn = open_data_file(path, "rb")
        if file then
            local size = file:seek("end") or 0
            local head, mid, tail = "", "", ""
            if size > 0 then
                file:seek("set", 0)
                head = file:read(64) or ""
                file:seek("set", math.max(size - 64, 0))
                tail = file:read(64) or ""
                file:seek("set", math.floor(size / 2))
                mid = file:read(64) or ""
            end
            close_file(file, close_fn)
            table.insert(sig_parts, path .. "::" .. size .. "::" .. head .. "::" .. mid .. "::" .. tail)
        else
            table.insert(sig_parts, path .. "::missing")
        end
    end
    return table.concat(sig_parts, "||")
end

-- 拼音归一化：统一转小写、去声调、过滤非字母字符
local function normalize_pinyin(text)
    text = trim(text)
    if text == "" then return "" end

    for tone, plain in pairs(TONE_MAP) do
        text = text:gsub(tone, plain)
    end

    return text:lower()
        :gsub("[^a-z%s]", " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

-- 为一个候选补充可检索编码：全拼 / 首字母 / zh ch sh 模糊形式
local function add_search_form(entry, form)
    form = trim(form)
    if form == "" or entry.form_seen[form] then return end
    entry.form_seen[form] = true
    table.insert(entry.forms, form)
end

local function add_pinyin_phrase(entry, raw_pinyin)
    local normalized = normalize_pinyin(raw_pinyin)
    if normalized == "" then return end

    local syllables = {}
    for syllable in normalized:gmatch("%S+") do
        table.insert(syllables, syllable)
    end
    if #syllables == 0 then return end

    add_search_form(entry, table.concat(syllables, ""))

    local initials = {}
    local fuzzy = {}
    local fuzzy_initials = {}
    for _, syllable in ipairs(syllables) do
        table.insert(initials, syllable:sub(1, 1))

        local fuzzy_syllable = syllable
            :gsub("^zh", "z")
            :gsub("^ch", "c")
            :gsub("^sh", "s")
        table.insert(fuzzy, fuzzy_syllable)
        table.insert(fuzzy_initials, fuzzy_syllable:sub(1, 1))
    end

    add_search_form(entry, table.concat(initials, ""))
    add_search_form(entry, table.concat(fuzzy, ""))
    add_search_form(entry, table.concat(fuzzy_initials, ""))
end

local function reset_entry_forms(entries)
    for _, entry in ipairs(entries) do
        entry.forms = {}
        entry.form_seen = {}
    end
end

local function get_entry_db_key(entry)
    return ENTRY_KEY_PREFIX .. entry.key .. TAB .. entry.text
end

-- 从 txt 加载基础数据
-- 格式：关键词 [tab] 颜文字
function kaomoji.load_entries(files)
    local entries = {}
    local seen = {}

    for _, file_path in ipairs(files) do
        local file, close_fn = open_data_file(file_path, "r")
        if file then
            for raw_line in file:lines() do
                local line = strip_bom(raw_line)
                if trim(line) ~= "" and not line:match("^%s*#") then
                    local key, text = line:match("^([^\t]+)\t(.+)$")
                    key = trim(key)
                    text = trim(text)
                    if key ~= "" and text ~= "" then
                        local uniq = key .. TAB .. text
                        if not seen[uniq] then
                            seen[uniq] = true
                            table.insert(entries, {
                                key = key,
                                text = text,
                                ascii_key = key:lower(),
                                forms = {},
                                form_seen = {},
                            })
                        end
                    end
                end
            end
            close_file(file, close_fn)
        end
    end

    return entries
end

-- 用万象现有词典补齐拼音，兼容只写“关键词 + 颜文字”的简洁格式
function kaomoji.enrich_entries(entries, dict_files)
    local wanted = {}
    for _, entry in ipairs(entries) do
        wanted[entry.key] = wanted[entry.key] or {}
        table.insert(wanted[entry.key], entry)
    end

    for _, file_path in ipairs(dict_files) do
        local file, close_fn = open_data_file(file_path, "r")
        if file then
            for raw_line in file:lines() do
                local line = strip_bom(raw_line)
                local word, pinyin = line:match("^([^\t]+)\t([^\t]+)")
                local matched = word and wanted[word]
                if matched and pinyin and pinyin ~= "" then
                    for _, entry in ipairs(matched) do
                        add_pinyin_phrase(entry, pinyin)
                    end
                end
            end
            close_file(file, close_fn)
        end
    end
end

local function ensure_db(env, writable)
    if not kaomoji.db or kaomoji.db_name ~= env.kmj_db_name then
        if kaomoji.db and kaomoji.db_mode then
            kaomoji.db:close()
        end
        kaomoji.db_name = env.kmj_db_name
        kaomoji.db = userdb.LevelDb(env.kmj_db_name)
        kaomoji.db_mode = nil
    end

    local mode = writable and "rw" or "ro"
    if kaomoji.db_mode == mode then return kaomoji.db end

    if kaomoji.db_mode then
        kaomoji.db:close()
    end
    if writable then
        kaomoji.db:open()
    else
        kaomoji.db:open_read_only()
    end
    kaomoji.db_mode = mode
    return kaomoji.db
end

local function load_forms_from_db(env, files_sig, dict_sig, entries)
    local db = ensure_db(env, false)
    if not db then return false end
    if db:meta_fetch(META_KEY.version) ~= wanxiang.version then return false end
    if (db:meta_fetch(META_KEY.files_sig) or "") ~= files_sig then return false end
    if (db:meta_fetch(META_KEY.dict_sig) or "") ~= dict_sig then return false end

    reset_entry_forms(entries)
    for _, entry in ipairs(entries) do
        local raw = db:fetch(get_entry_db_key(entry))
        if raw and raw ~= "" then
            for form in raw:gmatch("[^\t]+") do
                add_search_form(entry, form)
            end
        end
    end
    return true
end

local function save_forms_to_db(env, files_sig, dict_sig, entries)
    local db = ensure_db(env, true)
    if not db then return end

    local clear = db["clear"]
    if clear then
        clear(db)
    elseif db.empty then
        db:empty(true)
    end

    for _, entry in ipairs(entries) do
        if #entry.forms > 0 then
            db:update(get_entry_db_key(entry), table.concat(entry.forms, TAB))
        end
    end

    db:meta_update(META_KEY.version, wanxiang.version)
    db:meta_update(META_KEY.files_sig, files_sig)
    db:meta_update(META_KEY.dict_sig, dict_sig)

    db:close()
    db:open_read_only()
    kaomoji.db_mode = "ro"
end

-- 基础缓存：文件内容变化时才重建基础条目，首次 /kmj 空查询只走这一层
function kaomoji.ensure_entries_loaded(env)
    local files_signature = generate_files_signature(env.kmj_files)
    if kaomoji.files_signature ~= files_signature then
        kaomoji.entries = kaomoji.load_entries(env.kmj_files)
        kaomoji.files_signature = files_signature
        kaomoji.dict_signature = nil
    end

    return kaomoji.entries
end

-- 拼音缓存：只有真正按拼音检索时，才扫描万象词典补齐编码
function kaomoji.ensure_dict_loaded(env)
    kaomoji.ensure_entries_loaded(env)

    local files_sig = kaomoji.files_signature or ""
    local dict_signature = table.concat(env.kmj_dict_files, "\n") .. "::" .. generate_files_signature(env.kmj_dict_files)
    if kaomoji.dict_signature ~= dict_signature then
        if not load_forms_from_db(env, files_sig, dict_signature, kaomoji.entries) then
            reset_entry_forms(kaomoji.entries)
            kaomoji.enrich_entries(kaomoji.entries, env.kmj_dict_files)
            save_forms_to_db(env, files_sig, dict_signature, kaomoji.entries)
        end
        kaomoji.dict_signature = dict_signature
    end

    return kaomoji.entries
end

-- 输入解析：仅接受 /kmj[a-z] 这类纯字母查询
local function parse_query(input, key)
    if input:sub(1, #key) ~= key then return nil end
    local query = input:sub(#key + 1):lower()
    if query:find("[^a-z]") then return nil end
    return query
end

-- 匹配策略：支持关键词前缀、拼音全拼、首字母与模糊简拼
local function match_entry(entry, query)
    if query == "" or entry.ascii_key:find(query, 1, true) then
        return true
    end

    for _, form in ipairs(entry.forms) do
        if form:find(query, 1, true) == 1 then
            return true
        end
    end
    return false
end

-- 收集候选：保持原文件顺序，同一颜文字只输出一次
local function collect_matches(env, query)
    local matched = {}
    local seen = {}
    local entries = query == "" and kaomoji.ensure_entries_loaded(env) or kaomoji.ensure_dict_loaded(env)

    for _, entry in ipairs(entries) do
        if match_entry(entry, query) and not seen[entry.text] then
            seen[entry.text] = true
            table.insert(matched, entry)
        end
    end

    return matched
end

-- 初始化：读取配置并预热 userdb 缓存
function kaomoji.init(env)
    local config = env.engine.schema.config
    local key = config:get_string("kaomoji/kaomoji_key") or DEFAULT_KEY
    local db_name = config:get_string("kaomoji/db_name") or DEFAULT_DB_NAME

    env.kmj_key = key ~= "" and key or DEFAULT_KEY
    env.kmj_db_name = db_name ~= "" and db_name or DEFAULT_DB_NAME
    env.kmj_files = get_configured_files(config)
    env.kmj_dict_files = get_dict_files()

    kaomoji.ensure_dict_loaded(env)
end

-- translator 主入口：解析 query、生成候选、按排序结果输出
function kaomoji.func(input, seg, env)
    local query = parse_query(input, env.kmj_key or DEFAULT_KEY)
    if query == nil then return end

    local yielded = 0
    for _, entry in ipairs(collect_matches(env, query)) do
        local cand = Candidate("kaomoji", seg.start, seg._end, entry.text, entry.key)
        cand.quality = 1000000 - yielded
        yield(cand)
        yielded = yielded + 1
        if yielded >= DEFAULT_MAX_CANDIDATES then
            return
        end
    end
end

return kaomoji
