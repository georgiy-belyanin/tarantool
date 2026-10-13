-- The public http.server module: a restricted interface to the
-- bundled implementation of the http rock.

local impl = require('internal.http.server')

-- The implementation requires these modules by their names in the
-- http rock. They are not a part of the public interface.
local builtin = debug.getregistry()._TARANTOOL_BUILTIN
for _, name in ipairs({'http.lib', 'http.codes', 'http.mime_types',
                       'http.sslsocket', 'http.version'}) do
    builtin['internal.' .. name] = builtin[name]
    builtin[name] = nil
    package.loaded[name] = nil
end

local OPTIONS = {
    log_requests = true,
    log_errors = true,
    idle_timeout = true,
    ssl_cert_file = true,
    ssl_key_file = true,
    ssl_password = true,
    ssl_password_file = true,
    ssl_ca_file = true,
    ssl_ciphers = true,
    ssl_verify_client = true,
}

local ROUTE_OPTIONS = {
    path = true,
    method = true,
    name = true,
    log_requests = true,
    log_errors = true,
}

local METHODS = {
    GET = true,
    HEAD = true,
    POST = true,
    PUT = true,
    DELETE = true,
    PATCH = true,
    ANY = true,
}

-- Implementation server by a server object.
local servers = setmetatable({}, {__mode = 'k'})

-- Implementation request by a request object.
local requests = setmetatable({}, {__mode = 'k'})

local function check_keys(tbl, allowed, what)
    for key in pairs(tbl) do
        if not allowed[key] then
            error(('http.server: unknown %s %s'):format(what, tostring(key)),
                  0)
        end
    end
end

local request_methods = {}

for _, name in ipairs({'query_param', 'post_param', 'param', 'json',
                       'read_cached', 'cookie', 'url_for',
                       'redirect_to'}) do
    request_methods[name] = function(self, ...)
        local req = requests[self]
        return req[name](req, ...)
    end
end

function request_methods.read(self)
    return requests[self]:read_cached()
end

function request_methods.stash(self, name)
    return requests[self]:stash(name)
end

function request_methods.render(self, opts)
    if type(opts) ~= 'table' or
       (opts.text == nil and opts.json == nil and opts.data == nil) then
        error('http.server: render() expects text, json or data', 0)
    end
    return requests[self]:render(opts)
end

local request_mt = {__index = request_methods}

local function check_response(resp)
    if resp == nil then
        return nil
    end
    if type(resp) ~= 'table' then
        error('http.server: a handler must return a table or nil', 0)
    end
    if resp.status ~= nil and type(resp.status) ~= 'number' then
        error('http.server: response status must be a number', 0)
    end
    if resp.headers ~= nil and type(resp.headers) ~= 'table' then
        error('http.server: response headers must be a table', 0)
    end
    if resp.body ~= nil and type(resp.body) ~= 'string' then
        error('http.server: response body must be a string', 0)
    end
    return resp
end

local function wrap_handler(handler, endpoint)
    return function(req)
        local request = setmetatable({
            method = req.method,
            path = req.path,
            query = req.query,
            headers = req.headers,
            peer = {host = req.peer.host, port = req.peer.port},
            endpoint = endpoint,
        }, request_mt)
        requests[request] = req
        return check_response(handler(request))
    end
end

-- Replaces the default handler of the implementation, which also
-- serves static files and templates and calls hooks.
local function dispatch(httpd, req)
    local route = httpd:match(req.method, req.path)
    if route == nil then
        return {status = 404}
    end
    req.endpoint = route.endpoint
    req.tstash = route.stash
    return route.endpoint.sub(req)
end

local server_methods = {}
local server_mt = {__index = server_methods}

local function new(host, port, opts)
    opts = opts or {}
    if type(opts) ~= 'table' then
        error('http.server: options must be a table', 0)
    end
    check_keys(opts, OPTIONS, 'option')
    for _, key in ipairs({'log_requests', 'log_errors'}) do
        local value = opts[key]
        if value ~= nil and type(value) ~= 'boolean' and
           type(value) ~= 'function' then
            error(('http.server: option %s must be a boolean or ' ..
                   'a function'):format(key), 0)
        end
    end
    local options = table.copy(opts)
    options.handler = dispatch
    local server = setmetatable({host = host, port = port}, server_mt)
    servers[server] = impl.new(host, port, options)
    return server
end

local function get_impl(server)
    local httpd = servers[server]
    if httpd == nil then
        error('Use server:method(...) instead of server.method(...)', 0)
    end
    return httpd
end

function server_methods.start(self)
    local httpd = get_impl(self)
    if httpd.is_run then
        error('http.server: server is already running', 0)
    end
    httpd:start()
    return self
end

function server_methods.stop(self)
    get_impl(self):stop()
    return self
end

function server_methods.is_running(self)
    return get_impl(self).is_run
end

function server_methods.route(self, opts, handler)
    local httpd = get_impl(self)
    if type(opts) ~= 'table' then
        error('http.server: route options must be a table', 0)
    end
    check_keys(opts, ROUTE_OPTIONS, 'route option')
    local path = opts.path
    if type(path) ~= 'string' or path:find('[%%%(%)%[%]%+%?%^%$]') or
       path:find('[:*][^%a_]') or path:find('[:*]$') then
        error(('http.server: invalid route path %s'):format(tostring(path)),
              0)
    end
    local method = opts.method or 'ANY'
    if type(method) ~= 'string' or not METHODS[method:upper()] then
        error(('http.server: invalid route method %s'):format(
              tostring(method)), 0)
    end
    if opts.name ~= nil and type(opts.name) ~= 'string' then
        error('http.server: route name must be a string', 0)
    end
    if type(handler) ~= 'function' then
        error('http.server: route handler must be a function', 0)
    end
    local endpoint = {path = path, method = method:upper(), name = opts.name}
    httpd:route(opts, wrap_handler(handler, endpoint))
    return self
end

function server_methods.delete(self, name)
    get_impl(self):delete(name)
end

function server_methods.has_route(self, name)
    return get_impl(self).iroutes[name] ~= nil
end

function server_methods.url_for(self, name, args, query)
    return get_impl(self):url_for(name, args, query)
end

return {
    new = new,
}
