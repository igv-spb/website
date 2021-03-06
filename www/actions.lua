--actions: the bulk of the web app.
package.loaded.cbrowser = nil
local glue = require'glue'
local lp = require'luapower'
local pp = require'pp'
local lfs = require'lfs'
local tuple = require'tuple'
local zip = require'minizip'
local lustache = require'lustache'
local grep = require'grep'
local cbrowser = require'cbrowser'

--in our current setup, the dependency db must be updated manually.
lp.config('auto_update_db', false)
lp.config('allow_update_db_locally', false)

local action = {} --action table: {action_name = action_handler}
local app = {} --HTTP API (to be set at runtime by the loader of this module)

--helpers --------------------------------------------------------------------

--filesystem

local function readwwwfile(name)
	return assert(glue.readfile(app.wwwpath(name)))
end

local function older(file1, file2)
	local mtime1 = lfs.attributes(file1, 'modification')
	local mtime2 = lfs.attributes(file2, 'modification')
	if not mtime1 then return true end
	if not mtime2 then return false end
	return mtime1 < mtime2
end

local function escape_filename(s)
	return s:gsub('[/\\%?%%%*%:|"<> ]', '-')
end

--rendering

local function render(name, data, env)
	lustache.renderer:clear_cache()
	local function get_partial(_, name)
		return readwwwfile(name:gsub('_(%w+)$', '.%1')) --'name_ext' -> 'name.ext'
	end
	local template = readwwwfile(name)
	env = setmetatable(env or {}, {__index = get_partial})
	return (lustache:render(template, data, env))
end

local function render_main(name, data, env)
	data.grep_enabled = app.grep_enabled
	return render('main.html',
		data,
		glue.merge({
			content = readwwwfile(name),
		}, env)
	)
end

--date/time formatting

local function rel_time(s)
	if s > 2 * 365 * 24 * 3600 then
		return ('%d years'):format(math.floor(s / (365 * 24 * 3600)))
	elseif s > 2 * 30.5 * 24 * 3600 then
		return ('%d months'):format(math.floor(s / (30.5 * 24 * 3600)))
	elseif s > 1.5 * 24 * 3600 then
		return ('%d days'):format(math.floor(s / (24 * 3600)))
	elseif s > 2 * 3600 then
		return ('%d hours'):format(math.floor(s / 3600))
	elseif s > 2 * 60 then
		return ('%d minutes'):format(math.floor(s / 60))
	else
		return 'a minute'
	end
end

local function timeago(time)
	local s = os.difftime(os.time(), time)
	return string.format(s > 0 and '%s ago' or 'in %s', rel_time(math.abs(s)))
end

local function format_time(time)
	return os.date('%b %e \'%y %H:%M', time)
end

local function format_date(time)
	return os.date('%b %e \'%y', time)
end

--widgets --------------------------------------------------------------------

local widgets = {}

function widgets.module_list(package)
	local origin_url = lp.git_origin_url(package)
	local t = lp.module_headers(package)
	local dt = {}
	local function _(...) dt[#dt+1] = string.format(...)..'\n' end
	local cat0
	_'<table width=100%%>'
	for i,t in ipairs(t) do
		local path = lp.modules(package)[t.module]
		local docpath = lp.docs(package)[t.module]

		local cat = t.name and t.name:match'^(.-)/[^/]+$' or 'other'
		if cat ~= cat0 then
			_(' <tr><td colspan=2><strong>%s</strong></td><td class="gray small" style="vertical-align: bottom">last updated</td></tr>', cat)
			cat0 = cat
		end

		local mtime = lp.git_file_time(package, path)
		if mtime then
			t.mtime = format_date(mtime)
			t.mtime_ago = timeago(mtime)
		end

		local tagline = lp.module_tagline(package, t.module)

		local doclink = docpath and string.format(' [<a href="/%s">doc</a>]', t.module) or ''

		_' <tr>'
			_ '  <td class=nowrap>'
			_('   <a href="%s/blob/master/%s?ts=3">%s</a>%s', origin_url, path, t.module, doclink)
			_ '  </td><td>'
			_('   %s', tagline or '')
			_ '  </td><td class=nowrap>'
			_('   <span class=time time="%s" reltime="%s">%s</span>', t.mtime, t.mtime_ago, t.mtime_ago)
			_ '  </td>'
		_' </tr>'
	end
	_'</table>'
	return table.concat(dt)
end

--doc rendering --------------------------------------------------------------

local function md_refs()
	local t = {}
	local refs = {}
	local function addref(s)
		if refs[s] then return end
		table.insert(t, string.format('[%s]: /%s', s, s))
		refs[s] = true
	end
	--add refs in the order in which uris are dispatched.
	for pkg in pairs(lp.installed_packages()) do
		addref(pkg)
	end
	for doc in pairs(lp.docs()) do
		addref(doc)
	end
	for file in lfs.dir(app.wwwpath'md') do
		if file:find'%.md$' then
			addref(file:match'^(.-)%.md$')
		end
	end
	table.insert(t, readwwwfile'ext-links.md')
	return table.concat(t, '\n')
end

local function render_docfile(infile)
	local outfile = app.wwwpath('.cache/'..escape_filename(infile)..'.html')
	if older(outfile, infile) then
		local s1 = glue.readfile(infile)
		local s2 = md_refs()
		local tmpfile = os.tmpname()
		glue.writefile(tmpfile, s1..'\n\n'..s2)
		local cmd = 'pandoc --tab-stop=3 -r markdown+definition_lists -w html '..
			tmpfile..' > '..outfile
		os.execute(cmd)
		os.remove(tmpfile)
	end
	return glue.readfile(outfile)
end

local function www_docfile(doc)
	local docfile = app.wwwpath('md/'..doc..'.md')
	if not lfs.attributes(docfile, 'mtime') then return end
	return docfile
end

local function action_docfile(docfile)
	local data = {}
	data.doc_html = render_docfile(docfile)
	local dtags = lp.docfile_tags(docfile)
	data.title = dtags.title
	data.tagline = dtags.tagline
	local mtime = lfs.attributes(docfile, 'mtime') --TODO: use git on the website repo
	data.doc_mtime = format_date(mtime)
	data.doc_mtime_ago = mtime and timeago(mtime)
	data.edit_link = string.format(
		'https://github.com/luapower/website/edit/master/www/md/%s',
			(docfile:match('/([^/]+)$')))
	app.out(render_main('doc.html', data))
end

--package info ---------------------------------------------------------------

local ljsrc = 'https://github.com/LuaJIT/LuaJIT/blob/master/src/'

local module_src_urls = {
	string    = ljsrc..'lib_string.c',
	table     = ljsrc..'lib_table.c',
	coroutine = ljsrc..'lib_base.c',
	package   = ljsrc..'lib_package.c',
	io        = ljsrc..'lib_io.c',
	math      = ljsrc..'lib_math.c',
	os        = ljsrc..'lib_os.c',
	_G        = ljsrc..'lib_base.c',
	debug     = ljsrc..'lib_debug.c',
	ffi       = ljsrc..'lib_ffi.c',
	bit       = ljsrc..'lib_bit.c',
	jit       = ljsrc..'lib_jit.c',
	['jit.util']    = ljsrc..'lib_jit.c',
	['jit.profile'] = ljsrc..'lib_jit.c',
}

local function source_url(pkg, path, mod)
	local url = module_src_urls[mod]
	if url then return url end
	if type(path) ~= 'string' then return end
	local url = lp.git_origin_url(pkg)
	if url:find'github%.com' then
		return string.format('%s/blob/master/%s?ts=3', url, path)
	else
		--NOTE: we don't have non-github browsable URLs yet,
		--so this is just a placeholder for now.
		return string.format('%s/master/%s', url, path)
	end
end

local os_list = {'mingw', 'linux', 'osx'}
local platform_list = {'mingw32', 'mingw64', 'linux32', 'linux64', 'osx32', 'osx64'}
local os_platforms = {
	mingw = {'mingw32', 'mingw64'},
	linux = {'linux32', 'linux64'},
	osx   = {'osx32', 'osx64'},
}

--create a custom-ordered list of possible platforms.
local ext_platform_list = {'all', 'common'}
for _,os in ipairs(os_list) do
	table.insert(ext_platform_list, os)
	glue.extend(ext_platform_list, os_platforms[os])
end

local platform_icon_titles = {
	mingw   = 'Windows',
	mingw32 = '32bit Windows',
	mingw64 = '64bit Windows',
	linux   = 'Linux',
	linux32 = '32bit Linux',
	linux64 = '64bit Linux',
	osx     = 'OS X',
	osx32   = '32bit OS X',
	osx64   = '64bit OS X',
}

--platform icons, in order, given a map of supported platforms. vis_only
--controls whether a missing platform show as disabled or not included at all.
--if both 32bit and 64bit platforms of the same OS are supported,
--the result is a single OS icon without the 32/64 label.
local function platform_icons(platforms, vis_only)
	local t = {}
	for _,p in ipairs(platform_list) do
		if not vis_only or platforms[p] then
			table.insert(t, {
				name = p,
				disabled = not platforms[p] and 'disabled' or nil,
			})
		end
	end
	--combine 32bit and 64bit icon pairs into OS icons
	local i = 1
	while i < #t do
		if t[i].name:match'^[^%d]+' == t[i+1].name:match'^[^%d]+' then
			if t[i].disabled == t[i+1].disabled then
				t[i].name = t[i].name:match'^([^%d]+)'
			else
				t[i].name = t[i].disabled and t[i+1].name or t[i].name
				t[i].disabled = nil
			end
			table.remove(t, i+1)
		end
		i = i + 1
	end
	--set the icon title
	for i,pt in ipairs(t) do
		pt.title = (pt.disabled and 'doesn\'t work on ' or 'works on ')..
			platform_icon_titles[pt.name]
	end
	return t
end

--given {place1 = {item1 = val1, ...}, ...}, extract items that are
--found in all places into the place indicated by all_key.
local function extract_common_keys(maps, all_key)
	--count occurences for each item
	local maxn = glue.count(maps)
	--if less than two places to group, don't group
	if maxn < 2 then return maps end
	local nt = {} --{item = n}
	local tt = {} --{item = val}
	for place, items in pairs(maps) do
		for item, val in pairs(items) do
			nt[item] = (nt[item] or 0) + 1
			tt[item] = tt[item] or val --val of 'all' is the val of the first item.
		end
	end
	--extract items found in all places
	local all = {}
	for item, n in pairs(nt) do
		if n == maxn then
			all[item] = tt[item]
		end
	end
	--add items not found in all places, to their original places
	local t = {[all_key] = next(all) and all}
	for place, items in pairs(maps) do
		for item, val in pairs(items) do
			if all[item] == nil then
				glue.attr(t, place)[item] = val
			end
		end
	end
	return t
end

--same as above, but use an "all-or-nothing strategy" of extraction
local function extract_common_keys_aot(maps, all_key)
	--count occurences for each item
	local maxn = glue.count(maps)
	--if less than two places to group, don't group
	if maxn < 2 then return maps end
	local nt = {} --{item = n}
	local tt = {} --{item = val}
	for place, items in pairs(maps) do
		for item, val in pairs(items) do
			nt[item] = (nt[item] or 0) + 1
			tt[item] = tt[item] or val --val of 'all' is the val of the first item.
		end
	end
	--check to see if all items were extracted
	local all_extracted = true
	for item, n in pairs(nt) do
		if n < maxn then
			all_extracted = false
		end
	end
	return all_extracted and {[all_key] = tt} or maps
end

--given {platform1 = {item1 = val1, ...}, ...}, group items that are
--common to the same OS into OS keys, and all-around common items
--into the all_key key, if given.
local function platform_maps(maps, all_key, aot)
	local extract = aot and extract_common_keys_aot or extract_common_keys
	--extract common items across all places, if all_key given
	maps = all_key and extract(maps, all_key) or glue.update({}, maps)
	--combine platforms per OS
	for _,os in ipairs(os_list) do
		local t = {}
		for _,platform in ipairs(os_platforms[os]) do
			t[platform] = maps[platform]
			maps[platform] = nil
		end
		glue.update(maps, extract(t, os))
	end
	return maps
end

--return the identifying icons for a package and a sorting string
local function package_icons(ptype, platforms, small)

	local has_lua = ptype:find'Lua'
	local has_ffi = ptype:find'ffi'

	local t = {}

	--add Lua/LuaJIT icon
	if has_ffi then
		table.insert(t, {
			name = 'luajit',
			title = 'written in Lua with ffi extension',
		})
	elseif has_lua then
		table.insert(t, {
			name = small and 'luas' or 'lua',
			title = 'written in Lua',
		})
	else
		table.insert(t, {
			name = small and 'luas' or 'lua',
			title = ptype .. ' package',
			invisible = 'invisible',
		})
	end

	--add platform icons
	if next(platforms) then --don't show platform icons for Lua modules
		glue.extend(t, platform_icons(platforms))
	end

	--create a "sorting string" that sorts the packages by platform support
	local st = {}
	local pt = glue.keys(platforms, true)
	table.insert(st, tostring(((has_lua or has_ffi) and #pt == 0)
		and 100 or #pt)) --portable vs cross-platform
	table.insert(st, has_ffi and 1 or has_lua and 2 or 0) --Lua vs Lua+ffi vs others
	table.insert(st, ptype) --type, just to sort others predictably too
	glue.extend(st, pt) --platforms, just to group the same combinations together
	local ss = table.concat(st, ';')

	return t, ss
end

--dependency lists

local function sorted_names(deps) --sort dependency lists by (kind, name)
	return glue.keys(deps, function(name1, name2)
		local kind1 = deps[name1].kind
		local kind2 = deps[name2].kind
		if kind1 == kind2 then return name1 < name2 end
		return kind1 < kind2
	end)
end

local function pdep_list(pdeps) --package dependency list
	local packages = {}
	local names = sorted_names(pdeps)
	for _,pkg in ipairs(names) do
		local pdep = pdeps[pkg]
		table.insert(packages, glue.update({
			dep_package = pkg,
			external = pdep and pdep.kind == 'external',
		}, pdep))
	end
	return packages
end

local function mdep_list(mdeps) --module dependency list
	local modules = {}
	local names = sorted_names(mdeps)
	for _,mod in ipairs(names) do
		local mt = mdeps[mod]
		table.insert(modules, glue.update({
			dep_module = mod,
		}, mt))
	end
	return modules
end

local function packages_of(dep_func, mod, pkg, platform)
	local t = {}
	for mod in pairs(dep_func(mod, pkg, platform)) do
		local dpkg = lp.module_package(mod)
		if dpkg and dpkg ~= pkg then --exclude self
			t[dpkg] = true
		end
	end
	return t
end

local function packages_of_many(dep_func, mod, pkg, platform)
	local t = {}
	for mod in pairs(mod) do
		glue.update(t, packages_of(dep_func, mod, pkg, platform))
	end
	return t
end

local function packages_of_all(dep_func, _, pkg, platform)
	return packages_of_many(dep_func, lp.modules(pkg), pkg, platform)
end

local function all_module_deps(pkg, platforms)
	local t = {}
	for platform in pairs(platforms) do
		t[platform] = {}
		for mod in pairs(lp.modules(pkg)) do
			glue.update(t[platform],
				lp.module_requires_loadtime_all(mod, pkg, platform))
		end
	end
	return t
end

local function package_dep_maps(pkg, platforms)
	local pts = {}
	for platform in pairs(platforms) do
		local pt = {}
		pts[platform] = pt
		local pext = packages_of_all(lp.module_requires_loadtime_ext, nil, pkg, platform)
		local pall = packages_of_all(lp.module_requires_loadtime_all, nil, pkg, platform)
		glue.update(pext, lp.bin_deps(pkg, platform))
		glue.update(pall, lp.bin_deps_all(pkg, platform))
		for p in pairs(pall) do
			pt[p] = {kind = pext[p] and 'external' or 'indirect'}
		end
	end
	return pts
end

local function package_bin_dep_maps(pkg, platforms)
	local pts = {}
	for platform in pairs(platforms) do
		local pt = {}
		pts[platform] = pt
		local pext = lp.bin_deps(pkg, platform)
		local pall = lp.bin_deps_all(pkg, platform)
		for p in pairs(pall) do
			pt[p] = {kind = pext[p] and 'external' or 'indirect'}
		end
	end
	return pts
end

local function package_rev_dep_maps(pkg, platforms)
	local pts = {}
	for platform in pairs(platforms) do
		local pt = {}
		pts[platform] = pt
		local pext = packages_of_all(lp.module_required_loadtime, nil, pkg, platform)
		local pall = packages_of_all(lp.module_required_loadtime_all, nil, pkg, platform)
		glue.update(pext, lp.rev_bin_deps(pkg, platform))
		glue.update(pall, lp.rev_bin_deps_all(pkg, platform))
		for p in pairs(pall) do
			pt[p] = {kind = pext[p] and 'external' or 'indirect'}
		end
	end
	return pts
end

local function filter(t1, t2)
	local dt = {}
	for k, v in pairs(t1) do
		if t2[k] then
			dt[k] = v
		end
	end
	return dt
end

local function module_package_dep_maps(pkg, mod, platforms)
	local pts = {}
	for platform in pairs(platforms) do
		local pext = packages_of(lp.module_requires_loadtime_ext, mod, pkg, platform)
		local pall = packages_of(lp.module_requires_loadtime_all, mod, pkg, platform)
		glue.update(pext, filter(lp.bin_deps(pkg, platform), lp.module_platforms(mod, pkg)))
		glue.update(pall, filter(lp.bin_deps_all(pkg, platform), lp.module_platforms(mod, pkg)))
		local pt = {}
		for p in pairs(pall) do
			pt[p] = {kind = pext[p] and 'direct' or 'indirect'}
		end
		pts[platform] = pt
	end
	return pts
end

local function module_runtime_package_dep_maps(pkg, mod, platforms)
	local pts = {}
	for platform in pairs(platforms) do
		local pdeps = packages_of(lp.module_requires_runtime, mod, pkg, platform)
		local pt = {}
		for p in pairs(pdeps) do
			pt[p] = {kind = 'direct'}
		end
		pts[platform] = pt
	end
	return pts
end

local function module_module_dep_maps(pkg, mod, platforms)
	local mts = {}
	local mint = lp.modules(pkg)
	for platform in pairs(platforms) do
		local mext = lp.module_requires_loadtime_ext(mod, pkg, platform)
		local mall = lp.module_requires_loadtime_all(mod, pkg, platform)
		local mt = {}
		for m in pairs(mall) do
			local pkg = lp.module_package(m)
			local path = lp.modules(pkg)[m]
			mt[m] = {
				kind = mext[m] and 'external'
					or mint[m] and 'internal' or 'indirect',
				dep_package = pkg,
				dep_source_url = source_url(pkg, path, m),
			}
		end
		mts[platform] = mt
	end
	return mts
end

local function module_runtime_module_dep_maps(pkg, mod, platforms)
	local mts = {}
	local mint = lp.modules(pkg)
	for platform in pairs(platforms) do
		local mrun = lp.module_requires_runtime(mod, pkg, platform)
		local mt = {}
		for m in pairs(mrun) do
			local pkg = lp.module_package(m)
			local path = lp.modules(pkg)[m]
			mt[m] = {
				kind = 'external',
				dep_package = pkg,
				dep_source_url = source_url(pkg, path, m),
			}
		end
		mts[platform] = mt
	end
	return mts
end

local function package_dep_lists(pdeps)
	local t = {}
	for _,platform in ipairs(ext_platform_list) do
		local pdeps = pdeps[platform]
		if pdeps then
			local icon = platform ~= 'all' and platform ~= 'common' and platform or nil
			local text = not icon and platform or nil
			table.insert(t, {
				icon = icon,
				text = text,
				packages = pdep_list(pdeps),
			})
		end
	end
	return t
end

local function module_dep_lists(mdeps)
	local t = {}
	for _,platform in ipairs(ext_platform_list) do
		local mdeps = mdeps[platform]
		if mdeps then
			local icon = platform ~= 'all' and platform ~= 'common' and platform or nil
			local text = not icon and platform or nil
			table.insert(t, {
				icon = icon,
				text = text,
				modules = mdep_list(mdeps),
			})
		end
	end
	return t
end

local function package_dep_matrix(pdeps)
	local names = {}
	local icons = {}
	local depmat = {}

	for _,platform in ipairs(ext_platform_list) do
		local pmap = pdeps[platform]
		if pmap then
			table.insert(icons, platform)
			for pkg in pairs(pmap) do
				names[pkg] = true
			end
		end
	end
	local depmat_names = glue.keys(names, true)
	for i, icon in ipairs(icons) do
		depmat[i] = {
			pkg = {},
			text = icon == 'all' and icon or nil,
			icon = icon ~= 'all' and icon or nil,
		}
		for j, pkg in ipairs(depmat_names) do
			local pt = pdeps[icon][pkg]
			depmat[i].pkg[j] = {
				checked = pt ~= nil,
				kind = pt and pt.kind,
			}
		end
	end
	return depmat, depmat_names
end

local function package_info(pkg, doc)

	local t = {package = pkg}

	--gather info
	local package_type = lp.package_type(pkg)
	local platforms = lp.platforms(pkg)
	local all_platforms =
		next(platforms)
			and platforms
			or glue.update({}, lp.config'platforms')
	local master_time = lp.git_master_time(pkg)
	local license = lp.license(pkg)
	local ctags = lp.what_tags(pkg) or {}
	local origin_url = lp.git_origin_url(pkg)
	local on_github = origin_url:find'github%.com'
	local git_version = lp.git_version(pkg)
	local git_tag = lp.git_tag(pkg)
	local released = git_tag and git_tag ~= '' and git_tag ~= 'dev' --tag "dev" is not a release
	local git_tags = lp.git_tags(pkg)
	local doc = doc or pkg
	local docs = lp.docs(pkg)
	local doc_path = docs[doc]
	local title = doc
	local tagline
	if doc_path then
		local dtags = lp.doc_tags(pkg, doc)
		title = dtags.title
		tagline = dtags.tagline
	end
	local package_cat = lp.package_cat(pkg)

	--top bar / github url
	t.origin_url = origin_url
	t.github_url = on_github and origin_url
	t.github_title = on_github and origin_url:gsub('^https://', '')

	--download / "Changes since..."
	t.git_tag = git_tag
	t.changes_url = released and on_github and string.format('%s/compare/%s...master', origin_url, git_tag)

	--download / releases
	t.git_tags = {}
	if released then
		for i=#git_tags,1,-1 do
			local tag = git_tags[i]
			local prevtag = git_tags[i-1]
			local mtime = lp.git_tag_time(pkg, tag)
			table.insert(t.git_tags, {
				tag = tag,
				time = format_date(mtime),
				reltime = timeago(mtime),
				changes_text = prevtag and 'Changes...' or 'Files...',
				changes_url = on_github and (prevtag
					and string.format('%s/compare/%s...%s', origin_url, prevtag, tag)
					or string.format('%s/tree/%s', origin_url, tag)),
			})
		end
	end
	t.has_git_tags = #t.git_tags > 0

	--package info / overview / supported platorms
	t.platforms = {}
	for i,p in ipairs(platform_list) do
		if platforms[p] then
			table.insert(t.platforms, {icon = p})
		end
	end
	if not next(t.platforms) then
		local runtime = package_type == 'Lua+ffi' and 'LuaJIT' or package_type == 'Lua' and 'Lua'
		table.insert(t.platforms, {name = runtime and 'all '..runtime..' platforms'})
	end

	--package info / docs
	--menubar / doc list
	t.docs = {}
	for name, path in glue.sortedpairs(docs) do
		table.insert(t.docs, {
			shortname = name:gsub('^'..glue.escape(pkg)..'[%._]', ''),
			name = name,
			path = path,
			source_url = source_url(pkg, path),
			selected = name == doc,
		})
	end
	t.has_docs = #t.docs > 0

	--doc page
	t.title = doc
	t.doc_path = doc_path
	t.title = title
	t.tagline = tagline
	t.edit_link = on_github and doc_path and origin_url..'/edit/master/'..doc_path

	--sidebar
	t.icons = package_icons(package_type, platforms)
	t.type = package_type
	t.version = git_version
	t.mtime = format_time(master_time)
	t.mtime_ago = timeago(master_time)
	t.license = license
	t.c_name = ctags.realname and ctags.realname ~= pkg and ctags.realname or nil
	t.c_version = ctags.version
	t.c_url = ctags.url

	--menubar / other packages in cat
	t.cats = {}
	for i,cat in ipairs(lp.cats()) do
		if cat.name == package_cat then
			local ct = {name = cat.name}
			table.insert(t.cats, ct)
			ct.packages = {}
			for i, package in ipairs(cat.packages) do
				table.insert(ct.packages, {
					package = package,
					selected = package == pkg,
				})
			end
		end
	end

	--package dependencies ----------------------------------------------------

	--combined package dependencies
	local pts = package_dep_maps(pkg, all_platforms)
	local pdeps = platform_maps(pts, 'common')
	t.package_deps = package_dep_lists(pdeps)
	t.has_package_deps = #t.package_deps > 0

	--combined package dependency matrix
	local pdeps_aot = platform_maps(pts, 'all', 'aot')
	t.depmat, t.depmat_names = package_dep_matrix(pdeps_aot)

	--package clone lists
	if not pdeps_aot.all then --make a combined list for all platforms
		local all = {}
		for platform, pts in pairs(pdeps_aot) do
			for package in pairs(pts) do
				all[package] = {}
			end
		end
		pdeps_aot.all = all
	end
	t.clone_lists = {}
	for _,platform in ipairs(ext_platform_list) do
		local pdeps = pdeps_aot[platform]
		if pdeps then
			local packages = {{dep_package = pkg}}
			local pdeps = pdep_list(pdeps)
			glue.extend(packages, pdeps)
			table.insert(t.clone_lists, {
				platform = platform,
				text = platform == 'all' and platform or nil,
				icon = platform ~= 'all' and platform or nil,
				is_unix = not platform:find'mingw',
				hidden = platform ~= 'all' and 'hidden' or nil,
				disabled = platform ~= 'all' and 'disabled' or nil,
				packages = packages,
			})
		end
	end

	--combined package reverse dependencies
	local pts = package_rev_dep_maps(pkg, all_platforms)
	local rpdeps = platform_maps(pts, 'common')
	t.package_rdeps = package_dep_lists(rpdeps)
	t.has_package_rdeps = #t.package_rdeps > 0

	--binary dependencies
	local pts = package_bin_dep_maps(pkg, all_platforms)
	local pdeps = platform_maps(pts, 'common')
	t.bin_deps = package_dep_lists(pdeps)
	t.has_bin_deps = #t.bin_deps > 0

	--build order
	local pts = {}
	for platform in pairs(all_platforms) do
		local bo = lp.build_order(pkg, platform)
		pts[platform] = {[tuple(unpack(bo))] = bo}
	end
	local bo = platform_maps(pts, 'all', 'aot')
	t.build_order = {}
	for _,platform in ipairs(ext_platform_list) do
		local bo = bo[platform]
		if bo then
			table.insert(t.build_order, {
				icon = platform ~= 'all' and platform,
				text = platform == 'all' and 'all',
				packages = {next(bo)()},
			})
		end
	end

	--module list -------------------------------------------------------------

	t.modules = {}
	for mod, path in glue.sortedpairs(lp.modules(pkg)) do
		local mt = {module = mod}
		table.insert(t.modules, mt)

		local mtags = lp.module_tags(pkg, mod)
		mt.lang = mtags.lang

		mt.source_url = source_url(pkg, path, mod)

		local mplatforms = lp.module_platforms(mod, pkg)

		mt.icons = {}
		if tuple(unpack(glue.keys(mplatforms, true))) ~=
			tuple(unpack(glue.keys(all_platforms, true)))
		then
			mt.icons = platform_icons(mplatforms, true)
		end

		--loadtime package deps
		local pts = module_package_dep_maps(pkg, mod, all_platforms)
		local pdeps = platform_maps(pts, 'all')
		mt.package_deps = package_dep_lists(pdeps)

		--loadtime module deps
		local mts = module_module_dep_maps(pkg, mod, all_platforms)
		local mdeps = platform_maps(mts, 'all')
		mt.module_deps = module_dep_lists(mdeps)

		--runtime package deps
		local pts = module_runtime_package_dep_maps(pkg, mod, all_platforms)
		local pdeps = platform_maps(pts, 'all')
		mt.runtime_package_deps = package_dep_lists(pdeps)
		mt.module_has_runtime_deps = #mt.runtime_package_deps > 0
		t.has_runtime_deps = t.has_runtime_deps or mt.module_has_runtime_deps

		--runtime module deps
		local mts = module_runtime_module_dep_maps(pkg, mod, all_platforms)
		local mdeps = platform_maps(mts, 'all')
		mt.runtime_module_deps = module_dep_lists(mdeps)

		--autoloads
		local auto = {}
		for platform in pairs(all_platforms) do
			local autoloads = lp.module_autoloads(mod, pkg, platform)
			if next(autoloads) then
				for k, mod in pairs(autoloads) do
					glue.attr(auto, platform)[tuple(k, mod)] = true
				end
			end
		end
		auto = platform_maps(auto, 'all')
		mt.autoloads = {}
		local function autoload_list(platform, auto)
			local t = {}
			local function cmp(k1, k2) --sort by (module_name, key)
				local k1, mod1 = k1()
				local k2, mod2 = k2()
				if mod1 == mod2 then return k1 < k2 end
				return mod1 < mod2
			end
			for k in glue.sortedpairs(auto, cmp) do
				local k, mod = k()
				local pkg = lp.module_package(mod)
				local impl_path = pkg and lp.modules(pkg)[mod]
				table.insert(t, {
					platform ~= 'all' and platform,
					key = k,
					path = path,
					impl_module = mod,
					impl_path = impl_path,
				})
			end
			return t
		end
		for platform, auto in glue.sortedpairs(auto) do
			glue.extend(mt.autoloads, autoload_list(platform, auto))
		end
		mt.module_has_autoloads = #mt.autoloads > 0
		t.has_autoloads = t.has_autoloads or mt.module_has_autoloads

		--load errors
		local errs = {}
		for platform in pairs(lp.module_platforms(mod, pkg)) do
			local err = lp.module_load_error(mod, pkg, platform)
			if err then
				errs[platform] = {[err] = true}
			end
		end
		errs = platform_maps(errs, 'all')
		mt.load_errors = {}
		for platform, errs in pairs(errs) do
			table.insert(mt.load_errors, {
				icon = platform,
				errors = glue.keys(errs, true),
			})
		end
		mt.module_has_load_errors = #mt.load_errors > 0
		t.has_load_errors = t.has_load_errors or mt.module_has_load_errors
	end
	t.has_modules = glue.count(t.modules, 1) > 0


	local all_package_deps = package_dep_maps(pkg, all_platforms)
	local all_module_deps = all_module_deps(pkg, all_platforms)

	--script list
	t.scripts = {}
	for mod, path in glue.sortedpairs(lp.scripts(pkg)) do
		local st = {}
		table.insert(t.scripts, st)

		st.module = mod
		st.path = path
		st.source_url = source_url(pkg, path, mod)

		local mts = glue.update({}, lp.module_requires_parsed(mod))
		local pts = {}
		for mod in pairs(mts) do
			local pkg = lp.module_package(mod)
			if pkg then
				pts[pkg] = true
			end
		end

		st.package_deps = glue.keys(pts, true)

		st.module_deps = {}
		for mod in glue.sortedpairs(mts) do
			local pkg = lp.module_package(mod)
			local path = lp.modules(pkg)[mod] or lp.scripts(pkg)[mod]
			table.insert(st.module_deps, {
				dep_module = mod,
				dep_source_url = source_url(pkg, path, mod),
			})
		end

	end
	t.has_scripts = #t.scripts > 0

	return t
end

local function action_package(pkg, doc, what)
	local t = package_info(pkg, doc)
	if what == 'info' then
		t.info = true
	elseif what == 'download' then
		t.download = true
	elseif what == 'cc' then
		action.clear_cache(pkg)
		return
	elseif not what then
		if t.doc_path then
			local path = lp.powerpath(t.doc_path)
			t.doc_html = render_docfile(path)

			--add any widgets
			t.doc_html = t.doc_html:gsub('{{([^}]+)}}', function(name)
				local widget = widgets[name]
				if not widget then return '' end
				return widget(pkg)
			end)

			local mtime = lp.git_file_time(pkg, t.doc_path)
			if mtime then
				t.doc_mtime = format_date(mtime)
				t.doc_mtime_ago = timeago(mtime)
			end
		end
	end
	app.out(render_main('package.html', t))
end

local function action_home()
	local data = {}
	local pt = {}
	data.packages = pt
	for pkg in glue.sortedpairs(lp.installed_packages()) do
		if lp.known_packages()[pkg] then --exclude "luapower-repos"
			local t = {name = pkg}
			t.type = lp.package_type(pkg)
			t.platforms = lp.platforms(pkg)
			t.icons, t.platform_string = package_icons(t.type, t.platforms, true)
			local dtags = lp.doc_tags(pkg, pkg)
			t.tagline = dtags and dtags.tagline
			local cat = lp.package_cat(pkg)
			t.cat = cat and cat.name
			t.version = lp.git_version(pkg)
			local mtime = lp.git_master_time(pkg)
			t.mtimestamp = mtime
			t.mtime = format_time(mtime)
			t.mtime_ago = timeago(mtime)
			t.license = lp.license(pkg)
			table.insert(pt, t)
			t.hot = math.abs(os.difftime(os.time(), mtime)) < 3600 * 24 * 7
		end
	end
	data.github_title = 'github.com/luapower'
	data.github_url = 'https://'..data.github_title

	local pkgmap = {}
	for _,pkg in ipairs(data.packages) do
		pkgmap[pkg.name] = pkg
	end
	data.cats = {}
	for i, cat in ipairs(lp.cats()) do
		local t = {}
		for i, pkg in ipairs(cat.packages) do
			local pt = pkgmap[pkg]
			table.insert(t, pt)
		end
		table.insert(data.cats, {cat = cat.name, packages = t})
	end

	local file = 'files/luapower-all.zip'
	local size = lfs.attributes(app.wwwpath(file), 'size')
	local size = string.format('%d MB', size / 1024 / 1024)
	data.all_download_size = size

	app.out(render_main('home.html', data))
end

--status page ----------------------------------------------------------------

function action.status()
	local statuses = {}
	for platform, server in glue.sortedpairs(lp.config'servers') do
		local ip, port = unpack(server)
		local t = {platform = platform, ip = ip, port = port}
		local rlp, err = lp.connect(platform, nil, app.connect)
		t.status = rlp and 'up' or 'down'
		t.error = err and err:match'^.-:.-: ([^\n]+)'
		if rlp then
			t.os, t.arch = rlp.osarch()
			t.installed_package_count = glue.count(rlp.installed_packages())
			t.known_package_count = glue.count(rlp.known_packages())
			t.load_errors = {}
			for mod, err in glue.sortedpairs(lp.load_errors(nil, platform)) do
				table.insert(t.load_errors, {
					module = mod,
					error = err,
				})
			end
			t.load_error_count = #t.load_errors
		end
		table.insert(statuses, t)
	end
	app.out(render_main('status.html', {statuses = statuses}))
end

--grepping through the source code and documentation -------------------------

local disallow = glue.index{'{}', '()', '))', '}}', '==', '[[', ']]', '--'}
function action.grep(s)
	local results = {search = s}
	if not s or #glue.trim(s) < 2 or disallow[s] then
		results.message = 'Type two or more non-space characters and not '..
			table.concat(glue.keys(disallow), ', ')..'.'
	else
		app.sleep(1) --sorry about this
		glue.update(results, grep(s, 10))
		results.title = 'grepping for '..(s or '')
		results.message = #results.results > 0 and '' or 'Nothing found.'
		results.searched = true
	end
	app.out(render_main('grep.html', results))
end

--update via github ----------------------------------------------------------

function action.github(...)
	if not app.POST then return end
	local repo = app.POST.repository.name
	if not repo then return end
	if not lp.installed_packages()[repo] then return end
	os.execute(lp.git(repo, 'pull')) --TODO: this is blocking the server!!!
	lp.update_db(repo) --TODO: this is blocking the server!!!
end

--dependency lister for git clone --------------------------------------------

action['deps.txt'] = function(pkg)
	app.setmime'txt'
	local deps = lp.package_requires_packages_for(
		'module_requires_loadtime_all', pkg, nil, true)
	for k in glue.sortedpairs(deps) do
		app.out(k)
		app.out'\n'
	end
end

--clearing the cache and updating the deps db --------------------------------

function action.clear_cache(package)
	app.setmime'txt'
	lustache.renderer:clear_cache()
	lp.clear_cache(package)
	lp.unload_db()
	app.out('cache cleared for '..(package or 'all')..'\n')
end

function action.update_db(package)
	action.clear_cache(package)
	lp.update_db(package)
	lp.save_db()
	app.out'db updated and saved\n'
end

--creating rockspecs ---------------------------------------------------------

local function action_rockspec(pkg)
	pkg = pkg:match'^luapower%-([%w_]+)'
	local dtags = lp.doc_tags(pkg, pkg)
	local tagline = dtags and dtags.tagline or pkg
	local homepage = 'http://luapower.com/'..pkg
	local license = lp.license(pkg)
	local pext = package_deps(lp.module_requires_loadtime_ext, pkg, platform)
	local deps = {}
	for pkg in glue.sortedpairs(pext) do
		table.insert(deps, 'luapower-'..pkg)
	end
	local plat = {}
	local plats = {
		mingw32 = 'windows', mingw64 = 'windows',
		linux32 = 'linux', linux64 = 'linux',
		osx32 = 'macosx', osx64 = 'macosx',
	}
	for pl in pairs(lp.platforms(pkg)) do
		plat[plats[pl]] = true
	end
	plat = next(plat) and glue.keys(plat, true) or nil
	local ver = lp.git_version(pkg)
	local maj, min = ver:match('^([^%-]+)%-([^%-]+)')
	if maj then
		maj = maj:gsub('[^%d]', '')
		min = min:gsub('[^%d]', '')
		ver = '0.'..maj..'-'..min
	end
	local lua_modules = {}
	local luac_modules = {}
	for mod, path in pairs(lp.modules(pkg)) do
		local mtags = lp.module_tags(pkg,	 mod)
		if mtags.lang == 'C' then
			luac_modules[mod] = path
		elseif mtags.lang == 'Lua' or mtags.lang == 'Lua/ASM' then
			lua_modules[mod] = path
		end
	end
	local t = {
		package = 'luapower-'..pkg,
		supported_platforms = plat,
		version = ver,
		source = {
			url = lp.git_origin_url(pkg),
		},
		description = {
			summary = tagline,
			homepage = homepage,
			license = license,
		},
		dependencies = deps,
		build = {
			type = 'none',
			install = {
				lua = lua_modules,
				lib = luac_modules,
			},
		},
		--copy_directories = {},
	}
	app.setmime'txt'
	for k,v in glue.sortedpairs(t) do
		app.out(k)
		app.out' = '
		app.out(pp.format(v, '   '))
		app.out'\n'
	end
end

--action cbrowser ------------------------------------------------------------

function action.cbrowser(...)
	app.out(render_main('cbrowser.html', cbrowser(...)))
end

--action dispatch ------------------------------------------------------------

function action.default(s, ...)
	local hs = s and s:match'^(.-)%.html$'
	if not s then
		return action_home()
	elseif lp.installed_packages()[hs or s] then
		return action_package(hs or s, nil, ...)
	elseif lp.docs()[hs or s] then
		local pkg = lp.doc_package(hs or s)
		return action_package(pkg, hs or s, ...)
	elseif s:find'%.rockspec$' then
		local pkg = s:match'^(.-)%.rockspec$'
		if not lp.installed_packages()[pkg] then
			app.redirect'/'
		end
		action_rockspec(pkg)
	else
		local docfile = www_docfile(hs or s)
		if docfile then
			return action_docfile(docfile, ...)
		else
			app.redirect'/'
		end
	end
end

return {
	action = action,
	app = app,
}

