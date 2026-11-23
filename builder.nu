#!/usr/bin/env nu
# Arch package repo builder. See README.md.
#
#   nu builder.nu plan [--force]   check sources against the hosted repo, write work/plan.nuon
#   nu builder.nu build <target>   build the plan's packages for one target (root, inside the builder image)
#   nu builder.nu publish          sign, repo-add/remove, upload, delete stale files, then index
#   nu builder.nu index            write browsable index.html listings into the remote
#
# Env: BUILDER_CONFIG (default ./config.toml), WORK (default ./work), REMOTE (overrides config),
#      RCLONE_CONFIG / RCLONE_CONFIG_<NAME>_* (read by rclone), SIGNING_KEY (path to the sq secret key, publish only).

use lib.nu *

const ROOT = path self | path dirname
const CERT = path self | path dirname | path join keys repo.pgp
# gpg -> gpg-sq shim from the image, so makepkg verifies sources with Sequoia
const SQ_GPG = '/usr/local/lib/sequoia-gpg'
# Hosted layout: <remote>/<DISTRO>/<target>/, leaving room for other distros next to it
const DISTRO = 'archlinux'

def config [] {
    let cfg = open ($env.BUILDER_CONFIG? | default ($ROOT | path join config.toml))
    $cfg | upsert remote ($env.REMOTE? | default $cfg.remote | str trim -r -c '/')
}

def work [...parts: string] { $env.WORK? | default ($ROOT | path join work) | path expand | path join ...$parts }

def remote [cfg: record, ...parts: string] { [$cfg.remote $DISTRO ...$parts] | str join '/' }

# Metadata files kept next to the packages: remote name -> local name (repo-add wants the .tar.zst names).
def meta-files [repo: string] {
    [
        { remote: $"($repo).db", local: $"($repo).db.tar.zst" }
        { remote: $"($repo).files", local: $"($repo).files.tar.zst" }
        { remote: $"($repo).state.nuon", local: $"($repo).state.nuon" }
    ]
}

# Run an external and return its stdout; fail on a non-zero exit even though it's piped.
def --wrapped out [cmd: string, ...args: string] {
    let r = run-external $cmd ...$args | complete
    if $r.exit_code != 0 { error make { msg: $"($cmd) ($args | str join ' ') failed: ($r.stderr | str trim)" } }
    $r.stdout
}

def verify [file: string] {
    # `complete`, not `| ignore`: piping an external swallows its exit code
    let r = ^sqv --keyring $CERT --signature-file $"($file).sig" $file | complete
    if $r.exit_code != 0 { error make { msg: $"bad signature on ($file | path basename): ($r.stderr | str trim)" } }
}

def sign [key: string, file: string] {
    ^sq --home=none --overwrite sign --signer-file $key --binary --signature-file $"($file).sig" $file err> /dev/null
}

# `rclone lsjson` records for a remote dir; [] if the dir doesn't exist yet.
def remote-entries [path: string, --files-only] {
    let flags = if $files_only { [--files-only] } else { [] }
    let r = ^rclone lsjson ...$flags $path | complete
    if $r.exit_code == 3 { return [] }
    if $r.exit_code != 0 { error make { msg: $"rclone lsjson failed: ($r.stderr)" } }
    $r.stdout | from json
}

# File names in a remote target dir; [] if the dir doesn't exist yet.
def remote-ls [cfg: record, target: string] {
    remote-entries (remote $cfg $target) --files-only | get -o Name | default []
}

def read-db [path: string] {
    if not ($path | path exists) { return [] }
    let tmp = mktemp --directory --tmpdir 'builder-db.XXXXXX'
    ^bsdtar -xf $path -C $tmp
    let rows = glob $"($tmp)/*/desc" | each {|f| open --raw $f | parse-desc }
    rm -rf $tmp
    $rows
}

# Download and verify a target's db, files db and state into `dir`.
def fetch-meta [cfg: record, target: string, dir: string] {
    mkdir $dir
    let names = remote-ls $cfg $target
    for m in (meta-files $cfg.repo) {
        if $m.remote not-in $names { continue }
        if $"($m.remote).sig" not-in $names { error make { msg: $"($target)/($m.remote) has no signature" } }
        let local = $dir | path join $m.local
        ^rclone copyto (remote $cfg $target $m.remote) $local
        ^rclone copyto (remote $cfg $target $"($m.remote).sig") $"($local).sig"
        verify $local
    }
    let state = $dir | path join $"($cfg.repo).state.nuon"
    {
        db: (read-db ($dir | path join $"($cfg.repo).db.tar.zst"))
        state: (if ($state | path exists) { open $state } else { {} })
    }
}

def ls-remote [url: string, ref: string] {
    let hit = out git ls-remote $url $ref | lines | split column "\t" commit ref | where ref == $ref
    if ($hit | is-empty) { error make { msg: $"($url): ref ($ref) not found" } }
    $hit.0.commit
}

# Clone a configured source and collect what the planner needs.
def prepare-source [cfg: record, src: record, dir: string] {
    let branch = if $src.ref? != null { [--branch $src.ref] } else { [] }
    ^git clone --quiet --depth 1 --no-tags ...$branch $src.url $dir
    let sub = $src.path? | default ''
    let pkgdir = $dir | path join $sub
    let info = open --raw ($pkgdir | path join .SRCINFO) | parse-srcinfo
    let targets = $info | targets-for $cfg.targets $src.targets?
    # upstream heads, per arch since source_<arch> entries may differ
    let entries = $targets
        | each {|t| $cfg.targets | get $t | get arch } | uniq
        | each {|a| { arch: $a, vcs: ($info | vcs-sources $a | where not untracked) } }
    let commits = $entries | get vcs | flatten | uniq-by key
        | reduce -f {} {|e acc| $acc | insert $e.key (ls-remote $e.url $e.ref) }
    let heads = $entries | reduce -f {} {|e acc|
        $acc | insert $e.arch ($e.vcs | reduce -f {} {|v h| $h | insert $v.key ($commits | get $v.key) })
    }
    {
        id: $info.pkgbase
        info: $info
        targets: $targets
        pkgdir: $pkgdir
        commit: (out git -C $dir rev-parse HEAD | str trim)
        tree: (out git -C $dir rev-parse $"HEAD:($sub)" | str trim)
        heads: $heads
    }
}

# Check every source against the hosted repo and write work/plan.nuon.
def "main plan" [--force] {
    let cfg = config
    let tnames = $cfg.targets | columns
    rm -rf (work)
    mkdir (work sources)

    let sources = $cfg.sources | enumerate | each {|it|
        print $"checking ($it.item.url) ($it.item.path? | default '')"
        prepare-source $cfg $it.item (work clones $"($it.index)")
    }
    let dups = $sources | get id | uniq -d
    if ($dups | is-not-empty) { error make { msg: $"duplicate pkgbase in sources: ($dups | str join ', ')" } }

    let metas = $tnames | reduce -f {} {|t acc| $acc | insert $t (fetch-meta $cfg $t (work meta $t)) }
    let facts = $sources | each {|s|
        let reasons = $s.targets | reduce -f {} {|t acc|
            let m = $metas | get $t
            let heads = $s.heads | get ($cfg.targets | get $t | get arch)
            $acc | insert $t ($s.info | needs-build $m.db $m.state $heads $s.tree --force=$force)
        }
        $s | insert reasons $reasons
    }
    let plan = $facts | make-plan $tnames
    let removals = $tnames | reduce -f {} {|t acc| $acc | insert $t (($metas | get $t).db | removals ($plan.expected | get $t)) }

    # hand the exact packaging dirs to the build jobs
    for s in $facts { cp -r $s.pkgdir (work sources $s.id); rm -rf (work sources $s.id .git) }
    rm -rf (work clones)

    let out = $plan | merge {
        force: $force
        removals: $removals
        hosted: ($tnames | reduce -f {} {|t acc| $acc | insert $t (($metas | get $t).db | is-not-empty) })
        sources: ($facts | reduce -f {} {|s acc|
            $acc | insert $s.id { pkgbase: $s.id, pkgnames: $s.info.pkgnames, targets: $s.targets, tree: $s.tree, heads: $s.heads }
        })
    }
    $out | to nuon --indent 2 | save -f (work plan.nuon)

    let matrix = $tnames | where {|t| ($plan.builds | get $t | is-not-empty) } | each {|t|
        let c = $cfg.targets | get $t
        { target: $t, runner: $c.runner, image: $c.image }
    }
    let has_work = ($tnames | any {|t| ($plan.publish | get $t | is-not-empty) or ($removals | get $t | is-not-empty) })
    $matrix | to json --raw | save -f (work matrix.json)
    $has_work | to json | save -f (work has_work)

    $facts | each {|s| $s.reasons | transpose target reason | insert pkgbase $s.id } | flatten
        | where reason != null | select pkgbase target reason | print
    $tnames | each {|t| { target: $t, build: ($plan.builds | get $t), remove: ($removals | get $t) } } | print
}

# Point pacman at the run's own packages (and the hosted repo) ahead of the distro repos.
def add-repo [name: string, server: string, siglevel: string] {
    let conf = open --raw /etc/pacman.conf
    if ($conf | str contains $"[($name)]") { return }
    let section = $"[($name)]\nSigLevel = ($siglevel)\nServer = ($server)\n\n[core]"
    $conf | str replace -r '(?m)^\[core\]' $section | save -f /etc/pacman.conf
}

# Build the planned packages for one target. Runs as root inside the builder image.
def "main build" [target: string] {
    let cfg = config
    let plan = open (work plan.nuon)
    let tcfg = $cfg.targets | get $target
    if (^id -u | str trim) != '0' { error make { msg: 'build runs as root inside the builder image' } }

    let out = work out $target
    mkdir $out
    ^chown -R builder:builder (work sources) $out

    if $tcfg.makepkg_conf? != null { $tcfg.makepkg_conf | save -f /etc/makepkg.conf.d/50-target.conf }
    if $cfg.public_url? != null and ($plan.hosted | get $target) {
        ^pacman-key --add $CERT
        let fpr = out sq --home=none inspect $CERT | parse -r 'Fingerprint: (?<f>[0-9A-F]+)' | get 0.f
        ^pacman-key --lsign-key $fpr
        add-repo $cfg.repo $"($cfg.public_url | str trim -r -c '/')/($target)" Required
    }
    ^pacman -Syu --noconfirm

    let results = $plan.builds | get $target | each {|id|
        print $"::group::($id)"
        let dir = work sources $id
        let env_ = [$"PATH=($SQ_GPG):/usr/bin" $"PKGDEST=($out)"]
        for k in (glob $"($dir)/keys/pgp/*.asc") { ^sudo -u builder -H env ...$env_ gpg --import $k }
        let ok = try {
            cd $dir
            ^sudo -u builder -H env ...$env_ makepkg --syncdeps --rmdeps --cleanbuild --noconfirm --noprogressbar
            true
        } catch { false }
        let files = if $ok {
            cd $dir
            ^sudo -u builder -H env ...$env_ makepkg --packagelist | lines | where { path exists } | path basename
        } else { [] }
        if ($files | is-not-empty) {
            # later sources may depend on this one
            ^repo-add -q ($out | path join localbuild.db.tar.zst) ...($files | each {|f| $out | path join $f })
            add-repo localbuild $"file://($out)" 'Optional TrustAll'
            ^pacman -Sy
        }
        print '::endgroup::'
        { id: $id, ok: ($ok and ($files | is-not-empty)), files: $files }
    }
    $results | where ok | select id files | to nuon | save -f ($out | path join built.nuon)
    let failed = $results | where not ok | get id
    if ($failed | is-not-empty) {
        print -e $"failed: ($failed | str join ', ')"
        exit 1
    }
}

# Sign, update dbs and state, upload, then delete files the dbs no longer reference.
def "main publish" [--key: string] {
    let cfg = config
    let plan = open (work plan.nuon)
    let key = $key | default $env.SIGNING_KEY?
    if $key == null { error make { msg: 'no signing key: pass --key or set SIGNING_KEY' } }

    # the key must match keys/repo.pgp, or the next plan can't verify what we upload
    let probe = mktemp --tmpdir 'builder-probe.XXXXXX'
    sign $key $probe
    verify $probe
    rm -f $probe $"($probe).sig"

    let built = glob (work out '*' built.nuon) | each {|f|
        open $f | insert dir ($f | path dirname)
    } | flatten
    # one signing key for every distro, so it sits at the remote's root
    ^rclone copyto $CERT ([$cfg.remote repo.pgp] | str join '/')

    for t in ($cfg.targets | columns) {
        let ids = $plan.publish | get $t | where {|id| $id in ($built | get -o id | default []) }
        if ($ids | is-empty) and ($plan.removals | get $t | is-empty) { continue }
        print $"== ($t)"
        let stage = work publish $t
        let m = fetch-meta $cfg $t $stage
        let db = $stage | path join $"($cfg.repo).db.tar.zst"

        let pkgs = $stage | path join pkgs
        mkdir $pkgs
        let files = $ids | each {|id|
            let b = $built | where id == $id | first
            $b.files | each {|f| cp ($b.dir | path join $f) $pkgs; $pkgs | path join $f }
        } | flatten
        for f in $files { sign $key $f }
        if ($files | is-not-empty) { ^repo-add -q $db ...$files }

        let expected = $plan.expected | get $t
        let gone = read-db $db | removals $expected
        if ($gone | is-not-empty) { ^repo-remove -q $db ...$gone }

        let arch = $cfg.targets | get $t | get arch
        let done = $ids | each {|id| let s = $plan.sources | get $id; { pkgbase: $id, tree: $s.tree, heads: ($s.heads | get $arch) } }
        let keep = $plan.sources | values | where {|s| $t in $s.targets } | get pkgbase
        $m.state | next-state $done $keep | to nuon --indent 2 | save -f ($stage | path join $"($cfg.repo).state.nuon")

        # packages first, then the metadata pointing at them, then cleanup
        if ($files | is-not-empty) { ^rclone copy $pkgs (remote $cfg $t) }
        let up = $stage | path join up
        mkdir $up
        for mf in (meta-files $cfg.repo) {
            let f = $up | path join $mf.remote
            cp ($stage | path join $mf.local) $f
            sign $key $f
        }
        ^rclone copy $up (remote $cfg $t)

        let stale = remote-ls $cfg $t | unreferenced (read-db $db | get -o filename | default [])
        for f in $stale { ^rclone deletefile (remote $cfg $t $f) }
        print $"added: ($files | where {|f| not ($f | str ends-with .sig) } | path basename | length), removed: ($gone | length), deleted files: ($stale | length)"
    }
    main index
}

# Write an index.html into the remote root, <distro>/ and every target dir, so the repo can be browsed.
def "main index" [] {
    let cfg = config
    let stage = work index
    mkdir $stage
    # deepest first: writing a target's index.html creates its folder, which the parent listing should show
    let dirs = [
        ...($cfg.targets | columns | each {|t| { path: (remote $cfg $t), title: $"/($DISTRO)/($t)/", parent: true } })
        { path: (remote $cfg), title: $"/($DISTRO)/", parent: true }
        { path: $cfg.remote, title: '/', parent: false }
    ]
    for d in $dirs {
        let f = $stage | path join 'index.html'
        remote-entries $d.path | index-html $d.title --parent=$d.parent | save -f $f
        ^rclone copyto $f $"($d.path)/index.html"
    }
    print $"indexed ($dirs | length) folders"
}

def main [] { help main }
