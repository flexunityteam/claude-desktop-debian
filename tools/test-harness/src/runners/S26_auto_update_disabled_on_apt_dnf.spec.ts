import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

const exec = promisify(execFile);

// S26 — Auto-update is disabled when installed via apt/dnf.
//
// Per docs/testing/cases/distribution.md S26:
//   Expected: when installed via the project's APT or DNF repo, the
//   in-app auto-update path is suppressed. The app does not download
//   replacement binaries (which would race the package manager).
//   Updates flow through `apt upgrade` / `dnf upgrade` only. AppImage
//   installs may continue to self-update or punt to the user.
//
// **Suppression shipped** (issue #567): `scripts/frame-fix-wrapper.js`
// replaces Electron's `autoUpdater` with a chainable no-op Proxy on
// Linux (`autoUpdaterNoop`, frame-fix-wrapper.js:144-153, returned
// from the `require('electron')` get-trap at :974-989). Upstream's
// bundled `setFeedURL(...)` / `.checkForUpdates()` calls land on the
// Proxy and do nothing, regardless of whether a future Electron
// implements the Linux autoUpdater. The wrapper is packed into the
// asar root by scripts/patches/app-asar.sh, so it is probeable as an
// asar file — no app launch needed.
//
// **Drift-detector shape.** Two layers:
//
//   1. Sanity assertion: `setFeedURL` is present in the bundled
//      main-process JS. This proves the upstream auto-update code
//      path being suppressed is actually in the bundle — without it,
//      the rest of the test would be vacuously true. If this drops
//      to 0 (upstream rewrite/rename), re-ground the test.
//
//   2. Suppression assertion: `frame-fix-wrapper.js` inside the asar
//      contains the autoUpdater no-op fingerprints. If the wrapper
//      is renamed, the Proxy refactored away, or app-asar.sh stops
//      packing it, this fails and the suppression contract must be
//      re-verified by hand before updating MARKERS.
//
// **Skip behaviour.** Case-doc scopes this to "all DEB/RPM rows" —
// AppImage installs are explicitly carved out ("AppImage installs
// may continue to self-update or punt to the user"). We detect deb
// or rpm install via `dpkg-query -W claude-desktop` and `rpm -q
// claude-desktop`; if neither succeeds, we skip. On hosts where
// both succeed (mixed-tooling dev box), we run — the assertion
// shape is purely about what's in the bundle, not about which
// package manager owns the on-disk binary.
//
// Layer: pure file probe (asar read) + spawn probes for install
// detection. No app launch.

interface ProbeResult {
	cmd: string;
	exitCode: number | null;
	stdout: string;
	stderr: string;
}

async function probe(
	bin: string,
	args: string[],
): Promise<ProbeResult> {
	const cmd = `${bin} ${args.join(' ')}`;
	try {
		const { stdout, stderr } = await exec(bin, args, {
			timeout: 5_000,
		});
		return {
			cmd,
			exitCode: 0,
			stdout: stdout.trim(),
			stderr: stderr.trim(),
		};
	} catch (err) {
		const e = err as {
			stdout?: string;
			stderr?: string;
			code?: number | string;
		};
		const code =
			typeof e.code === 'number' ? e.code : null;
		return {
			cmd,
			exitCode: code,
			stdout: (e.stdout ?? '').trim(),
			stderr: (e.stderr ?? '').trim(),
		};
	}
}

// Suppression fingerprints in the shipped implementation
// (scripts/frame-fix-wrapper.js, packed into the asar root by
// scripts/patches/app-asar.sh). ALL must be present — together they
// pin both halves of the mechanism: the no-op Proxy definition and
// the require('electron') get-trap that swaps it in on Linux.
//
// We deliberately don't match `disableAutoUpdates` — that string is
// ALREADY in the bundle as the enterprise-policy MDM key
// (index.js:140737, :140830 etc), so its presence proves nothing.
const SUPPRESSION_MARKERS: { needle: string; rationale: string }[] = [
	{
		needle: 'const autoUpdaterNoop = new Proxy(',
		rationale:
			'the chainable no-op Proxy definition ' +
			'(frame-fix-wrapper.js:144) that absorbs ' +
			'.on/.setFeedURL/.checkForUpdates calls',
	},
	{
		needle: "prop === 'autoUpdater' && process.platform === 'linux'",
		rationale:
			"the require('electron') get-trap gate " +
			'(frame-fix-wrapper.js:974) that swaps the real ' +
			'autoUpdater for the no-op Proxy on Linux only',
	},
];

// The asar file the suppression lives in. app-asar.sh copies
// scripts/frame-fix-wrapper.js to the asar root and points the
// package.json `main` entry at a shim that requires it.
const WRAPPER_ASAR_PATH = 'frame-fix-wrapper.js';

test('S26 — Auto-update is disabled when installed via apt/dnf', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Critical',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / auto-update suppression',
	});

	// Detect install method. S26 only applies to deb/rpm-installed
	// hosts per case-doc "Applies to: All DEB/RPM rows".
	const dpkgProbe = await probe('dpkg-query', [
		'-W',
		'-f=${Version}',
		'claude-desktop',
	]);
	const rpmProbe = await probe('rpm', ['-q', 'claude-desktop']);

	await testInfo.attach('install-probes', {
		body: JSON.stringify(
			{
				dpkg: {
					cmd: dpkgProbe.cmd,
					exitCode: dpkgProbe.exitCode,
					stdout: dpkgProbe.stdout,
					stderr: dpkgProbe.stderr,
				},
				rpm: {
					cmd: rpmProbe.cmd,
					exitCode: rpmProbe.exitCode,
					stdout: rpmProbe.stdout,
					stderr: rpmProbe.stderr,
				},
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	const debInstalled = dpkgProbe.exitCode === 0 && !!dpkgProbe.stdout;
	const rpmInstalled = rpmProbe.exitCode === 0 && !!rpmProbe.stdout;
	const installMethod = debInstalled
		? 'deb'
		: rpmInstalled
			? 'rpm'
			: 'none';

	await testInfo.attach('install-method', {
		body: installMethod,
		contentType: 'text/plain',
	});

	if (!debInstalled && !rpmInstalled) {
		test.skip(
			true,
			'S26 only applies to deb/rpm-installed claude-desktop ' +
				'(case-doc scopes to APT/DNF rows; AppImage installs ' +
				'are explicitly carved out)',
		);
		return;
	}

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// Sanity assertion: the upstream autoUpdater code path is in the
	// bundle. If `setFeedURL` ever disappears (upstream rewrite,
	// module rename), this whole test is vacuous and should be
	// re-grounded against the new shape before re-asserting on the
	// suppression direction.
	const setFeedURLCount = (
		indexJs.match(/setFeedURL/g) ?? []
	).length;

	// Probe the suppression markers in the packed wrapper module.
	let wrapperJs = '';
	let wrapperReadError: string | null = null;
	try {
		wrapperJs = readAsarFile(WRAPPER_ASAR_PATH, asarPath);
	} catch (err) {
		wrapperReadError = err instanceof Error ? err.message : String(err);
	}

	const markerResults = SUPPRESSION_MARKERS.map((m) => ({
		needle: m.needle,
		rationale: m.rationale,
		found: wrapperJs.includes(m.needle),
	}));
	const allMarkersFound =
		wrapperReadError === null && markerResults.every((r) => r.found);

	await testInfo.attach('bundle-evidence', {
		body: JSON.stringify(
			{
				upstreamFile: '.vite/build/index.js',
				setFeedURLOccurrences: setFeedURLCount,
				wrapperFile: WRAPPER_ASAR_PATH,
				wrapperReadError,
				suppressionMarkers: markerResults,
				allMarkersFound,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		setFeedURLCount,
		'app.asar contains the upstream `setFeedURL` autoUpdater code ' +
			'path (sanity check — the thing S26 suppresses). ' +
			'If this drops to 0 the test is vacuous; re-ground against ' +
			'the new bundle shape.',
	).toBeGreaterThan(0);

	expect(
		wrapperReadError,
		`app.asar contains ${WRAPPER_ASAR_PATH} (packed by ` +
			'scripts/patches/app-asar.sh — the module carrying the ' +
			'autoUpdater suppression). If this fails, the wrapper was ' +
			'renamed or app-asar.sh stopped packing it.',
	).toBeNull();

	// Core S26 assertion: the shipped suppression (#567) is intact —
	// both the no-op Proxy and the Linux get-trap that installs it.
	expect(
		allMarkersFound,
		'frame-fix-wrapper.js inside app.asar contains the autoUpdater ' +
			'no-op fingerprints (deb/rpm installs must not race the ' +
			'package manager). If a marker went missing, the #567 ' +
			'suppression was refactored or removed — re-verify the ' +
			'contract and update SUPPRESSION_MARKERS.',
	).toBe(true);
});
