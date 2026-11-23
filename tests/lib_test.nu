use std/assert
use std/testing *
use ../lib.nu *

const SPLIT = 'pkgbase = foo
	pkgdesc = A split package
	pkgver = 1.2.3
	pkgrel = 2
	epoch = 1
	arch = x86_64
	arch = aarch64
	source = foo-1.2.3.tar.gz::https://example.org/foo-1.2.3.tar.gz
	source_aarch64 = arm.patch
	sha256sums = SKIP

pkgname = foo
	depends = glibc

pkgname = foo-docs
	arch = any
'

const VCS = 'pkgbase = bar-git
	pkgver = r10.abc1234
	pkgrel = 1
	arch = any
	source = bar::git+https://example.org/bar.git
	source = git+https://example.org/lib.git#branch=dev?signed
	source = git+https://example.org/pinned.git#tag=v1
	source = git+https://example.org/fixed.git#commit=deadbeef
	source = svn+https://example.org/svn/trunk
	source = local.patch

pkgname = bar-git
'

const TARGETS = {
    x86_64: { arch: x86_64 }
    aarch64: { arch: aarch64 }
    aarch64-v8.2: { arch: aarch64 }
}

# --- parse-srcinfo ---

@test
def srcinfo-split-package-with-epoch [] {
    let i = $SPLIT | parse-srcinfo
    assert equal $i.pkgbase foo
    assert equal $i.version '1:1.2.3-2'
    assert equal $i.pkgnames [foo foo-docs]
    # pkgname-level arch overrides don't leak into the pkgbase arch list
    assert equal $i.arch [x86_64 aarch64]
}

@test
def srcinfo-keeps-per-arch-sources [] {
    let i = $SPLIT | parse-srcinfo
    assert equal ($i.sources | get '') ['foo-1.2.3.tar.gz::https://example.org/foo-1.2.3.tar.gz']
    assert equal $i.sources.aarch64 ['arm.patch']
}

@test
def srcinfo-without-epoch [] {
    let i = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n\npkgname = a\n" | parse-srcinfo
    assert equal $i.version '1-1'
    assert equal $i.sources {}
}

@test
def srcinfo-without-pkgbase-fails [] {
    assert error { "pkgname = a\n" | parse-srcinfo }
}

# --- parse-desc ---

@test
def desc-fields [] {
    let d = "%FILENAME%\nfoo-docs-1:1.2.3-2-any.pkg.tar.zst\n\n%NAME%\nfoo-docs\n\n%BASE%\nfoo\n\n%VERSION%\n1:1.2.3-2\n\n%DESC%\nDocs\n" | parse-desc
    assert equal $d { name: foo-docs, base: foo, version: '1:1.2.3-2', filename: 'foo-docs-1:1.2.3-2-any.pkg.tar.zst' }
}

@test
def desc-base-defaults-to-name [] {
    let d = "%FILENAME%\na-1-1-any.pkg.tar.zst\n\n%NAME%\na\n\n%VERSION%\n1-1\n" | parse-desc
    assert equal $d.base a
}

# --- vcs-sources / is-vcs ---

@test
def vcs-git-refs [] {
    let v = $VCS | parse-srcinfo | vcs-sources x86_64 | where not untracked
    assert equal $v [
        { key: 'https://example.org/bar.git', url: 'https://example.org/bar.git', ref: HEAD, untracked: false }
        { key: 'https://example.org/lib.git#branch=dev', url: 'https://example.org/lib.git', ref: 'refs/heads/dev', untracked: false }
    ]
}

@test
def vcs-pinned-refs-are-skipped [] {
    let keys = $VCS | parse-srcinfo | vcs-sources x86_64 | get key
    assert ('https://example.org/pinned.git#tag=v1' not-in $keys)
    assert ('https://example.org/fixed.git#commit=deadbeef' not-in $keys)
}

@test
def vcs-other-kinds-are-untracked [] {
    let u = $VCS | parse-srcinfo | vcs-sources x86_64 | where untracked
    assert equal $u [{ key: 'https://example.org/svn/trunk', untracked: true }]
}

@test
def vcs-per-arch-sources [] {
    let i = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = aarch64\n\tsource_aarch64 = git+https://e/a.git\n\npkgname = a\n" | parse-srcinfo
    assert equal ($i | vcs-sources x86_64) []
    assert equal ($i | vcs-sources aarch64 | get key) ['https://e/a.git']
    assert ($i | is-vcs)
}

@test
def vcs-unknown-fragment-fails [] {
    let i = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n\tsource = git+https://e/a.git#bogus=1\n\npkgname = a\n" | parse-srcinfo
    assert error { $i | vcs-sources x86_64 }
}

@test
def is-vcs-detection [] {
    assert ($VCS | parse-srcinfo | is-vcs)
    assert not ($SPLIT | parse-srcinfo | is-vcs)
    let pinned = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n\tsource = git+https://e/a.git#tag=v1\n\npkgname = a\n" | parse-srcinfo
    assert not ($pinned | is-vcs)
}

# --- targets-for ---

@test
def targets-by-arch [] {
    assert equal ($SPLIT | parse-srcinfo | targets-for $TARGETS) [x86_64 aarch64 aarch64-v8.2]
    let x86 = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = x86_64\n\npkgname = a\n" | parse-srcinfo
    assert equal ($x86 | targets-for $TARGETS) [x86_64]
}

@test
def targets-any-and-override [] {
    let i = $VCS | parse-srcinfo
    assert equal ($i | targets-for $TARGETS) [x86_64 aarch64 aarch64-v8.2]
    assert equal ($i | targets-for $TARGETS [aarch64-v8.2]) [aarch64-v8.2]
    # an override can't add a target the PKGBUILD doesn't support
    let x86 = "pkgbase = a\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = x86_64\n\npkgname = a\n" | parse-srcinfo
    assert equal ($x86 | targets-for $TARGETS [aarch64]) []
}

# --- needs-build ---

def db [...rows] { $rows | each {|r| { name: $r.0, version: $r.1, filename: $"($r.0)-($r.1).pkg.tar.zst" } } }

@test
def build-when-missing [] {
    let r = $SPLIT | parse-srcinfo | needs-build (db [foo '1:1.2.3-2']) {} {} t1
    assert str contains $r 'foo-docs'
    assert ($SPLIT | parse-srcinfo | needs-build null {} {} t1 | is-not-empty)
}

@test
def build-on-version-change [] {
    let r = $SPLIT | parse-srcinfo | needs-build (db [foo '1:1.2.3-1'] [foo-docs '1:1.2.3-1']) {} {} t1
    assert equal $r '1:1.2.3-1 -> 1:1.2.3-2'
}

@test
def up-to-date [] {
    let r = $SPLIT | parse-srcinfo | needs-build (db [foo '1:1.2.3-2'] [foo-docs '1:1.2.3-2']) {} {} t1
    assert equal $r null
}

@test
def force-rebuilds [] {
    let r = $SPLIT | parse-srcinfo | needs-build (db [foo '1:1.2.3-2'] [foo-docs '1:1.2.3-2']) {} {} t1 --force
    assert equal $r forced
}

const HEADS = { 'https://example.org/bar.git': aaa, 'https://example.org/lib.git#branch=dev': bbb }

@test
def vcs-up-to-date-ignores-version [] {
    # the built pkgver never matches .SRCINFO for VCS packages
    let state = { bar-git: { tree: t1, heads: $HEADS } }
    let r = $VCS | parse-srcinfo | needs-build (db [bar-git 'r99.fff-1']) $state $HEADS t1
    assert equal $r null
}

@test
def vcs-upstream-moved [] {
    let state = { bar-git: { tree: t1, heads: $HEADS } }
    let r = $VCS | parse-srcinfo | needs-build (db [bar-git 'r99.fff-1']) $state ($HEADS | upsert 'https://example.org/lib.git#branch=dev' ccc) t1
    assert equal $r 'upstream moved: https://example.org/lib.git#branch=dev'
}

@test
def vcs-new-upstream-source [] {
    let state = { bar-git: { tree: t1, heads: { 'https://example.org/bar.git': aaa } } }
    let r = $VCS | parse-srcinfo | needs-build (db [bar-git 'r99.fff-1']) $state $HEADS t1
    assert str contains $r 'upstream moved'
}

@test
def vcs-packaging-changed [] {
    let state = { bar-git: { tree: t1, heads: $HEADS } }
    let r = $VCS | parse-srcinfo | needs-build (db [bar-git 'r99.fff-1']) $state $HEADS t2
    assert equal $r 'packaging changed'
}

@test
def vcs-no-state [] {
    let r = $VCS | parse-srcinfo | needs-build (db [bar-git 'r99.fff-1']) {} $HEADS t1
    assert equal $r 'no build state'
}

# --- make-plan ---

def src [id: string, arch: list, targets: list, reasons: record] {
    { id: $id, info: { pkgbase: $id, pkgnames: [$id], arch: $arch }, targets: $targets, reasons: $reasons }
}

@test
def plan-arch-specific [] {
    let p = [(src a [x86_64 aarch64] [x86_64 aarch64] { x86_64: 'v', aarch64: null })] | make-plan [x86_64 aarch64]
    assert equal $p.builds { x86_64: [a], aarch64: [] }
    assert equal $p.publish { x86_64: [a], aarch64: [] }
    assert equal $p.expected { x86_64: [a], aarch64: [a] }
}

@test
def plan-any-builds-once [] {
    let p = [(src a [any] [x86_64 aarch64 aarch64-v8.2] { x86_64: null, aarch64: 'v', aarch64-v8.2: 'v' })] | make-plan [x86_64 aarch64 aarch64-v8.2]
    assert equal $p.builds { x86_64: [], aarch64: [a], aarch64-v8.2: [] }
    assert equal $p.publish { x86_64: [], aarch64: [a], aarch64-v8.2: [a] }
}

@test
def plan-keeps-config-order [] {
    let all = { x86_64: 'v' }
    let p = [(src b [x86_64] [x86_64] $all) (src a [x86_64] [x86_64] $all)] | make-plan [x86_64]
    assert equal $p.builds.x86_64 [b a]
}

@test
def plan-split-package-expected [] {
    let s = { id: foo, info: { pkgbase: foo, pkgnames: [foo foo-docs], arch: [x86_64] }, targets: [x86_64], reasons: { x86_64: null } }
    let p = [$s] | make-plan [x86_64 aarch64]
    assert equal $p.expected { x86_64: [foo foo-docs], aarch64: [] }
}

# --- removals / unreferenced ---

@test
def removals-of-dropped-packages [] {
    assert equal (db [a '1-1'] [b '1-1'] [c '1-1'] | removals [a c]) [b]
    assert equal (null | removals [a]) []
}

@test
def unreferenced-files [] {
    let files = [
        myrepo.db myrepo.db.sig myrepo.files myrepo.files.sig myrepo.state.nuon myrepo.state.nuon.sig
        a-1-1-x86_64.pkg.tar.zst a-1-1-x86_64.pkg.tar.zst.sig
        a-1-2-x86_64.pkg.tar.zst a-1-2-x86_64.pkg.tar.zst.sig
        gone-1-1-any.pkg.tar.xz
        orphan-1-1-any.pkg.tar.zst.sig
        README
    ]
    assert equal ($files | unreferenced [a-1-2-x86_64.pkg.tar.zst]) [
        a-1-1-x86_64.pkg.tar.zst a-1-1-x86_64.pkg.tar.zst.sig gone-1-1-any.pkg.tar.xz orphan-1-1-any.pkg.tar.zst.sig
    ]
}

# --- next-state ---

@test
def state-merge-and-drop [] {
    let state = { a: { tree: t1, heads: { u: x } }, b: { tree: t1, heads: {} }, gone: { tree: t0, heads: {} } }
    let s = $state | next-state [{ pkgbase: a, tree: t2, heads: { u: y } } { pkgbase: c, tree: t3, heads: {} }] [a b c]
    assert equal $s { a: { tree: t2, heads: { u: y } }, b: { tree: t1, heads: {} }, c: { tree: t3, heads: {} } }
}
