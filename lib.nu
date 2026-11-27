# Pure logic for the package builder: parsing and decisions, no IO.
# Everything here is covered by tests/; builder.nu does the IO around it.

# Package file and signature names this tool manages on the remote.
const PKG_RE = '\.pkg\.tar(\.[a-z0-9]+)?$'
const VCS_PREFIXES = [git svn hg bzr fossil]

# Parse a .SRCINFO into the parts the planner needs.
# Only pkgbase-level `arch` and `source*` keys are kept; split packages keep their names.
export def parse-srcinfo []: string -> record {
    let kv = $in
        | lines
        | str trim
        | where { $in != '' and not ($in | str starts-with '#') }
        | each {|l|
            let i = $l | str index-of ' = '
            if $i < 0 { error make { msg: $"malformed .SRCINFO line: ($l)" } }
            { key: ($l | str substring ..<$i), value: ($l | str substring ($i + 3).. ) }
        }
    let base_end = $kv | enumerate | where item.key == pkgname | get -o 0.index | default ($kv | length)
    let base = $kv | first $base_end
    let one = {|k| $base | where key == $k | get -o 0.value }
    let pkgbase = do $one pkgbase
    if $pkgbase == null { error make { msg: '.SRCINFO has no pkgbase' } }
    let pkgver = do $one pkgver
    let pkgrel = do $one pkgrel
    let epoch = do $one epoch
    let version = $"(if $epoch != null { $'($epoch):' } else { '' })($pkgver)-($pkgrel)"
    let sources = $base
        | where { $in.key == source or ($in.key | str starts-with 'source_') }
        | group-by { if $in.key == source { '' } else { $in.key | str replace 'source_' '' } }
        | transpose arch entries
        | reduce -f {} {|it acc| $acc | insert $it.arch ($it.entries | get value) }
    {
        pkgbase: $pkgbase
        version: $version
        pkgnames: ($kv | where key == pkgname | get value)
        arch: ($base | where key == arch | get value)
        sources: $sources
    }
}

# Parse one `desc` entry from a pacman sync db.
export def parse-desc []: string -> record {
    let fields = $in
        | str trim
        | split row "\n\n"
        | each {|block|
            let ls = $block | lines
            { key: ($ls.0 | str trim -c '%' | str lowercase), value: ($ls | skip 1 | str join "\n") }
        }
        | reduce -f {} {|f acc| $acc | upsert $f.key $f.value }
    {
        name: $fields.name
        base: ($fields.base? | default $fields.name)
        version: $fields.version
        filename: $fields.filename
    }
}

# VCS entries of a .SRCINFO for one arch (generic + source_<arch>).
# git entries with a moving ref get { key, url, ref }; pinned ones (tag/commit) are left out.
# Other VCS kinds can't be checked cheaply and come back as { key, untracked: true }.
export def vcs-sources [arch: string]: record -> list {
    let info = $in
    ($info.sources | get -o '' | default []) ++ ($info.sources | get -o $arch | default [])
    | each {|entry|
        let raw = $entry | split row '::' | last
        let m = $raw | parse -r '^(?<kind>[a-z]+)\+(?<rest>.+)$' | get -o 0
        if $m == null or $m.kind not-in $VCS_PREFIXES { return null }
        let parts = $m.rest | split row '#'
        let url = $parts.0 | str replace -r '\?signed$' ''
        let frag = $parts | get -o 1 | default '' | str replace -r '\?signed$' ''
        let key = if $frag == '' { $url } else { $"($url)#($frag)" }
        if $m.kind != git { return { key: $key, untracked: true } }
        let ref = match ($frag | split row '=') {
            [''] => 'HEAD'
            ['branch' $b] => $"refs/heads/($b)"
            ['tag' $_] | ['commit' $_] => null
            _ => (error make { msg: $"unknown git fragment '($frag)' in ($entry)" })
        }
        if $ref == null { null } else { { key: $key, url: $url, ref: $ref, untracked: false } }
    }
    | compact
    | uniq-by key
}

# Whether a source is a VCS package (any VCS entry for any arch, tracked or not).
export def is-vcs []: record -> bool {
    let info = $in
    $info.sources | columns | any {|a| ($info | vcs-sources $a | is-not-empty) }
}

# Target names a source builds for: configured targets whose arch the PKGBUILD allows
# (all of them for arch=any), narrowed by the source's own `targets` list if set.
export def targets-for [targets: record, only?: list]: record -> list {
    let info = $in
    $targets
    | transpose name cfg
    | where { ('any' in $info.arch) or ($in.cfg.arch in $info.arch) }
    | where { $only == null or $in.name in $only }
    | get name
}

# Hosted folder of a target under the distro folder: <arch>/<name>.
export def target-dir [targets: record, name: string]: nothing -> string {
    $"(($targets | get $name).arch)/($name)"
}

# Why a source must be rebuilt for a target, or null if it's up to date.
#   db:    table of { name, version, filename } from the target's db
#   state: the target's state record, keyed by pkgbase: { tree, heads }
#   heads: { <vcs key>: <commit> } as seen upstream right now
#   tree:  git tree id of the packaging directory
export def needs-build [db: any, state: record, heads: record, tree: string, --force]: record -> any {
    let info = $in
    if $force { return 'forced' }
    let have = $db | default [] | where name in $info.pkgnames
    let missing = $info.pkgnames | where {|n| $n not-in ($have | get name) }
    if ($missing | is-not-empty) { return $"not in repo: ($missing | str join ', ')" }
    if not ($info | is-vcs) {
        let stale = $have | where version != $info.version
        if ($stale | is-empty) { return null }
        return $"($stale.0.version) -> ($info.version)"
    }
    let prev = $state | get -o $info.pkgbase
    if $prev == null { return 'no build state' }
    if $prev.tree != $tree { return 'packaging changed' }
    let moved = $heads | transpose key commit | where {|h| ($prev.heads | get -o $h.key) != $h.commit }
    if ($moved | is-not-empty) { return $"upstream moved: ($moved.0.key)" }
    null
}

# Build/publish plan from per-source facts.
#   sources: list of { id, info, targets, reasons: { <target>: reason|null } }
# Returns { builds, publish, expected } keyed by target. Non-any sources build on every
# outdated target. arch=any sources build once (first outdated target) and publish to all
# outdated targets. `expected` holds every pkgname that belongs in each target's db.
export def make-plan [targets: list]: list -> record {
    let sources = $in
    let empty = $targets | reduce -f {} {|t acc| $acc | insert $t [] }
    $sources | reduce -f { builds: $empty, publish: $empty, expected: $empty } {|s acc|
        let outdated = $s.targets | where {|t| ($s.reasons | get -o $t) != null }
        let builders = if ('any' in $s.info.arch) { $outdated | first 1 } else { $outdated }
        let add = {|acc field items list|
            $items | reduce -f $acc {|t a| $a | update $field { let m = $in; $m | upsert $t (($m | get $t) ++ $list) } }
        }
        let acc = do $add $acc expected $s.targets $s.info.pkgnames
        let acc = do $add $acc builds $builders [$s.id]
        do $add $acc publish $outdated [$s.id]
    }
}

# Which of the run's builds a target publishes.
#   built:  list of { id, target, ... }, every target's successful builds
#   ids:    the plan's publish list for this target
#   builds: the plan's builds, keyed by target
# A source the plan built on this target comes from this target's build, never another
# target's, even if this one failed. One built elsewhere (arch=any) comes from the target
# that built it.
export def builds-for [target: string, ids: list, builds: record]: list -> list {
    let built = $in
    $ids | each {|id|
        let from = if $id in ($builds | get $target) { $target } else {
            $builds | transpose t ids | where {|b| $id in $b.ids } | get -o 0.t
        }
        $built | where {|b| $b.id == $id and $b.target == $from } | get -o 0
    } | compact
}

# Pkgnames in a db that no longer belong there.
export def removals [expected: list]: any -> list {
    $in | default [] | get name | where {|n| $n not-in $expected } | uniq
}

# Package files (and their .sig) on the remote that the db doesn't reference.
export def unreferenced [referenced: list]: list -> list {
    $in | where {|f|
        let pkg = $f | str replace -r '\.sig$' ''
        ($pkg =~ $PKG_RE) and ($pkg not-in $referenced)
    }
}

# New state after a publish: successful builds replace their entries, pkgbases that
# no longer belong to the target are dropped.
#   built: list of { pkgbase, tree, heads }
export def next-state [built: list, keep: list]: record -> record {
    let state = $in
    let merged = $built | reduce -f $state {|b acc| $acc | upsert $b.pkgbase { tree: $b.tree, heads: $b.heads } }
    $merged | transpose k v | where k in $keep | reduce -f {} {|it acc| $acc | insert $it.k $it.v }
}

# --- folder listings ---

def html-escape []: string -> string {
    $in | str replace -a '&' '&amp;' | str replace -a '<' '&lt;' | str replace -a '>' '&gt;' | str replace -a '"' '&quot;'
}

# Percent-encode a path segment, keeping RFC 3986 unreserved chars plus `:`, `@` and `+`.
def href-encode []: string -> string {
    $in | split chars | each {|c|
        if ($c =~ '^[A-Za-z0-9._~:@+-]$') { $c } else {
            $c | encode utf-8 | encode hex | split chars | chunks 2 | each { $"%($in | str join)" } | str join
        }
    } | str join
}

# HTML listing of one remote folder.
#   input: `rclone lsjson` records ({ Name, Size, ModTime, IsDir })
export def index-html [title: string, --parent]: list -> string {
    let entries = $in | where Name != 'index.html' | sort-by -c {|a b|
        if $a.IsDir != $b.IsDir { $a.IsDir } else { $a.Name < $b.Name }
    }
    let rows = $entries | each {|e|
        let name = if $e.IsDir { $"($e.Name)/" } else { $e.Name }
        # `./` so a name like `foo-1:2.0-1-any.pkg.tar.zst` isn't read as a URL scheme
        let href = $"./($e.Name | href-encode)(if $e.IsDir { '/' } else { '' })"
        let size = if $e.IsDir { '-' } else { $e.Size | into filesize | into string }
        let time = if $e.IsDir { '-' } else { $e.ModTime | into datetime | date to-timezone UTC | format date '%Y-%m-%d %H:%M' }
        $"<tr><td><a href=\"($href | html-escape)\">($name | html-escape)</a></td><td>($size)</td><td>($time)</td></tr>"
    }
    let rows = if $parent { ['<tr><td><a href="../">../</a></td><td></td><td></td></tr>'] ++ $rows } else { $rows }
    let title = $title | html-escape
    [
        '<!DOCTYPE html>'
        '<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        $"<title>Index of ($title)</title>"
        '<style>'
        ':root { color-scheme: light dark; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; }'
        'body { max-width: 72rem; margin: 2rem auto; padding: 0 1rem; }'
        'h1 { font-size: 1.2rem; font-weight: 600; }'
        'table { border-collapse: collapse; width: 100%; }'
        'th, td { text-align: left; padding: .25rem 1rem .25rem 0; white-space: nowrap; }'
        'th { border-bottom: 1px solid; opacity: .7; font-weight: 600; }'
        'td:first-child { white-space: normal; word-break: break-all; }'
        'td:nth-child(2), th:nth-child(2) { text-align: right; }'
        '</style></head><body>'
        $"<h1>Index of ($title)</h1>"
        '<table><thead><tr><th>Name</th><th>Size</th><th>Modified (UTC)</th></tr></thead><tbody>'
        ...$rows
        '</tbody></table></body></html>'
        ''
    ] | str join "\n"
}
