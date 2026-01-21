local Config = require("zlibrary.config")
local Api = require('zlibrary.api')

local function extract_md5_and_link(line)
    local md5 = line:match('href="/md5/([a-fA-F0-9]+)"')
    if md5 and #md5 == 32 then
        return md5
    end
    return nil
end

local function extract_title(line)
    local content = line:match('<div class="font%-bold text%-violet%-900 line%-clamp%-%[5%]" data%-content="([^"]+)"')
    if content then
        content = content:match("^%s*(.-)%s*$")
        content = content:gsub('"', '\\"')
        content = content:gsub("•", "\\u2022")
        print('Title: ', content)
        return content
    end
    return 'Could not retrieve title.'
end

local function extract_author(line)
    if line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*"') then
        local block = line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*" data%-content="[^"]+"')
        if block then
            local author = block:match('data%-content="([^"]+)"')
            if author then
                print("Author:", author)
                return author
            end
        end
    end
    return 'Could not retrieve author.'
end

local function extract_format(line)
    local div_text = line:match('<div class="text%-gray%-800[^>]*>[^<]+')
    if div_text then
        local content = div_text:match('>([^<]+)')
        if content then
            local format = content:match("([A-Z][A-Z]+)")
            if format then
                print('format: ', format)
                return format
            end
        end
    end
    return 'Could not retrieve format.'
end

local function extract_description(line)
    local div_block = line:match('<div[^>]*class="[^"]*line%-clamp%-%[2%][^"]*"[^>]*>(.-)</div>')
    print('desc: ', div_block)
    if div_block then
        local description = div_block
        description = description:gsub('<script[^>]*>.-</script>', '')
        description = description:gsub('<a[^>]*>.-</a>', '')
        description = description:gsub('<[^>]->', '')
        description = description:gsub('&[#a-zA-Z0-9]+;', '')
        description = description:gsub('^%s+', ''):gsub('%s+$', '')
        print("Description:", description)
        return description
    end
    print("Description: Could not retrieve")
    return 'Could not retrieve description.'
end

-- Check if external command is available
local function command_exists(cmd)
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*a")
    handle:close()
    return result and result ~= ""
end

-- Pure Lua socket-based HTTP implementation (fallback)
local function fetch_with_lua_socket(url)
    print('=== Trying pure Lua socket for URL:', url)
    
    local socket_ok, socket = pcall(require, "socket")
    local http_ok, http = pcall(require, "socket.http")
    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    
    if not (socket_ok and http_ok and ltn12_ok) then
        print('=== LuaSocket not available')
        return "no_socket", nil
    end
    
    local response_body = {}
    local res, code, response_headers, status = http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        sink = ltn12.sink.table(response_body),
        redirect = true,
    }
    
    if res and code == 200 then
        local body = table.concat(response_body)
        print('=== LuaSocket succeeded, got', #body, 'bytes')
        return "success", body
    else
        print('=== LuaSocket failed, code:', code, 'status:', status)
        return "socket_error", nil
    end
end

-- Try to fetch using external curl/wget command
local function fetch_with_external_command(url)
    print('=== Trying external command for URL:', url)
    
    -- Try curl first
    if command_exists("curl") then
        print('=== Using curl')
        local handle = io.popen('curl -L -s --max-time 20 "' .. url .. '" 2>&1')
        if handle then
            local result = handle:read("*a")
            local success = handle:close()
            if success and result and #result > 0 then
                print('=== curl succeeded, got', #result, 'bytes')
                return "success", result
            end
        end
    end
    
    -- Try wget as fallback
    if command_exists("wget") then
        print('=== Using wget')
        local temp_file = os.tmpname()
        local cmd = string.format('wget -q -O "%s" --timeout=20 "%s" 2>&1', temp_file, url)
        local handle = io.popen(cmd)
        if handle then
            handle:close()
            local f = io.open(temp_file, "r")
            if f then
                local result = f:read("*a")
                f:close()
                os.remove(temp_file)
                if result and #result > 0 then
                    print('=== wget succeeded, got', #result, 'bytes')
                    return "success", result
                end
            end
        end
    end
    
    return "no_external_command", nil
end

-- Improved Api.makeHttpRequest with better error handling
local function fetch_with_api(url)
    print('=== Trying Api.makeHttpRequest for:', url)
    
    local user_session = Config.getUserSession()
    local hostname = url:match("://([^/]+)")
    
    -- Try different header configurations
    local header_configs = {
        -- Minimal headers
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        },
        -- Standard headers
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
        },
        -- Full headers with session
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
            ["Host"] = hostname,
        }
    }
    
    for i, headers in ipairs(header_configs) do
        print('=== API attempt', i, 'with', #headers, 'headers')
        
        -- Add session cookie if available
        if user_session and user_session.user_id and user_session.user_key then
            headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", 
                                             user_session.user_id, user_session.user_key)
        end
        
        local success, http_result = pcall(function()
            return Api.makeHttpRequest{
                url = url,
                method = "GET",
                headers = headers,
                timeout = 20,
            }
        end)
        
        if not success then
            print('=== API call threw error:', http_result)
            goto next_attempt
        end
        
        if not http_result then
            print('=== API returned nil')
            goto next_attempt
        end
        
        -- Check for errors
        if http_result.error then
            print('=== API returned error:', http_result.error)
            goto next_attempt
        end
        
        -- Check status code
        local status_code = tonumber(http_result.status_code)
        if status_code == 200 and http_result.body and #http_result.body > 0 then
            print('=== API succeeded with attempt', i, 'got', #http_result.body, 'bytes')
            return "success", http_result.body
        else
            print('=== API attempt', i, 'failed - status:', status_code, 'body exists:', http_result.body ~= nil)
        end
        
        ::next_attempt::
    end
    
    return "api_failed", nil
end

function check_url(url)
    print('=== DEBUG: check_url called with:', url)
    
    -- Method 1: Try external command (curl/wget) - most reliable
    local ext_status, ext_data = fetch_with_external_command(url)
    if ext_status == "success" then
        return "success", ext_data
    end
    
    print('=== External command not available, trying alternative methods')
    
    -- Method 2: Try LuaSocket (pure Lua, no external dependencies)
    local socket_status, socket_data = fetch_with_lua_socket(url)
    if socket_status == "success" then
        return "success", socket_data
    end
    
    print('=== LuaSocket not available or failed, trying Api.makeHttpRequest')
    
    -- Method 3: Try Api.makeHttpRequest with multiple configurations
    local api_status, api_data = fetch_with_api(url)
    if api_status == "success" then
        return "success", api_data
    end
    
    -- All methods failed
    print('=== ERROR: All HTTP methods failed')
    print('=== Tried: external commands (curl/wget), LuaSocket, Api.makeHttpRequest')
    
    return "network_error", nil
end

function scraper(query)
    -- Try multiple working mirrors of Anna's Archive
    local aa_domains = {
        "annas-archive.org",
        "annas-archive.se",
        "annas-archive.gs",
        "annas-archive.li",
        "annas-archive.pm",
        "annas-archive.in",
    }

    local domain_counter = 0
    local protocols = {"https://"}
    local protocol_counter = 0
    local page = "1"

    if not query then
        query = ''
    end

    print('got query: ', query)

    local encoded_query = string.gsub(query, " ", "+")
    local languages = Config.getSearchLanguages()
    local ext = Config.getSearchExtensions()
    local order = Config.getSearchOrder()
    local src = 'lgli'
    local filters = ''

    if languages then
        for k, lang in pairs(languages) do
            filters = filters .. "&lang=" .. lang
        end
    end

    if ext then
        for k, e in pairs(ext) do
            filters = filters .. "&ext=" .. string.lower(e)
        end
    end

    if order[1] then
        filters = filters .. "&sort=" .. order[1]
    end

    if src then
        filters = filters .. "&src=" .. src
    end

    print('applying filters: ', filters)

    ::retry::
    domain_counter = domain_counter + 1
    if domain_counter > #aa_domains then
        domain_counter = 1
        protocol_counter = protocol_counter + 1
        if protocol_counter >= #protocols then
            return "All domains and protocols failed. Anna's Archive may be blocked or no working HTTP method available."
        end
    end
    
    local annas_url = protocols[protocol_counter + 1] .. aa_domains[domain_counter] .. "/"
    local url = string.format("%ssearch?page=%s&q=%s%s", annas_url, page, encoded_query, filters)
    
    print('Attempting URL:', url)
    print('Protocol:', protocols[protocol_counter + 1], 'Domain:', aa_domains[domain_counter])
    
    local status, data = check_url(url)

    if status == "network_error" or status == "dns_error" then
        print('Network/DNS error on ', annas_url)
        print('Checking different mirror ...')
        goto retry
    elseif status == "success" then
        print("=== HTTP request succeeded")

        if not data or data == "" then
            print('=== ERROR: No data received from server')
            print('=== Retrying with different mirror...')
            goto retry
        end

        print('=== SUCCESS: Received data, length:', #data)
        print('=== First 100 chars:', string.sub(data, 1, 100))

        local ddos_guard_needle = 'der-gray-100<!doctype html><html><head><title>DDoS-Guard</titl'

        if data:find(ddos_guard_needle, 1, true) then
            print("=== DDoS guard triggered, trying different mirror ...")
            goto retry
        end

        local split_pattern = 'pt-3 pb-3 border-b last:border-b-0 border-gray-100'
        
        result_html = split_pattern .. data
        
        segments = {}
        
        local start_pos = 1
        
        while true do
            local s, e = result_html:find(split_pattern, start_pos, true)
            if not s then break end
            
            local next_s = result_html:find(split_pattern, e + 1, true)
            
            local segment
            if next_s then
                segment = result_html:sub(s, next_s - 1)
                start_pos = next_s
            else
                segment = result_html:sub(s)
                start_pos = #result_html + 1
            end
            
            table.insert(segments, segment)
        end

        local book_lst = {}
        book_count = 0 

        for i, entry in ipairs(segments) do
            print("\n---- Entry #" .. i .. " ----\n")
            print(string.sub(entry, 1, 100))

            local md5 = extract_md5_and_link(entry)
            local link = nil
            
            if md5 then
                link = annas_url .. 'md5/' .. md5
                print('found link', link )
            else
                print('Couldnt fetch MD5 sum of entry, probs not a valid html segment.')
                goto continue
            end

            local book = {}
            book.title = extract_title(entry)
            book.author = extract_author(entry)
            book.format = extract_format(entry)
            book.description = extract_description(entry)
            book.md5 = md5
            book.link = link
            
            if string.find(entry, "lgli", 1, true) then
                book.download = 'lgli'

                if string.find(entry, "zlib", 1, true) then
                    book.download = book.download .. ' | zlib'
                end
            else
                if string.find(entry, "zlib", 1, true) then
                    book.download = 'zlib'
                end
            end

            local number_str = entry:match(" (%d+%.?%d*)MB · ")

            if number_str then
                book.size = number_str .. "MB"
            else
                number_str = 'NA'
            end

            print(book.download)

            table.insert(book_lst, book)
            book_count = book_count + 1
            
            ::continue::
        end

        print("found " .. book_count .. " entries")

        return book_lst
    else
        print('Unknown error on ', annas_url, ': ', status)
        print('Checking different mirror ...')
        goto retry
    end
    return "Unknown error occurred"
end

function sanitize_name(name)
    local sanitized = name
    sanitized = sanitized:gsub("[^%w._-]", "_")
    sanitized = sanitized:gsub(" ", "_")
    return sanitized
end

function save_file_bytes(path, bytes)
    local f, err = io.open(path, "wb")
    if not f then 
        return nil, "open failed: "..tostring(err) 
    end

    local ok, werr = f:write(bytes)
    f:close()
    if not ok then 
        return nil, "write failed: "..tostring(werr) 
    end

    return true, "saved file to: " .. path
end

function download_book(book, path)
    local lgli_exts = {
        [1] = ".li/",
        [2] = ".is/",
        [3] = ".rs/",
        [4] = ".st/",
    }

    for _, lgli_ext in ipairs(lgli_exts) do
        local filename = path .. "/" .. sanitize_name(book.title) .. '_'.. sanitize_name(book.author) .. '.' .. book.format
        lgli_url = "https://libgen" .. lgli_ext
        print(book.title)

        if not book.download then
            print('no source available')
            return "Failed, no download source available [lgli, zlib]."
        end
        
        if string.find(book.download, 'lgli', 1, true) then
            download_page = lgli_url .. "ads.php?md5=" .. book.md5
            print('download page on lgli: ', download_page)
            local status, data = check_url(download_page)

            if status == "network_error" then
                return "Failed, please check connection, Network/HTTP error: " .. (data or "")
            elseif status == "success" then
                print("Download page fetched successfully!")

                if not data then
                    print("No data received from download page")
                    goto continue
                end

                local download_link = data:match('href="([^"]*get%.php[^"]*)"')

                if download_link then
                    print("Found final link:", download_link)
                    local download_url = lgli_url .. download_link

                    local status, data = check_url(download_url)
                    print('status:\n', status)
                    print(filename)
                    
                    if status == "success" and data then
                        local status, msg = save_file_bytes(filename, data)
                        print(msg)
                        return filename
                    else
                        print("Failed to download file")
                        goto continue
                    end
                else
                    print("No matching link found.")
                    goto continue
                end
            end
        else
            print('book not available on libgen')
        end
        
        ::continue::
    end
    
    return 'Failed, could not fetch download link from source page.'
end

if ... == nil then
    print("Running as main script")
    local book_lst = scraper('Marx')
end
