// Installs the Editor script this app drives Unity through into a target Unity project.
//
// Kept free of any electron import so it can be unit-tested with plain node, and so the
// Mac app's Swift port has a single obvious reference implementation to mirror.
//
// Why install at all: the app talks to Unity exclusively through -executeMethod entry
// points in Editor/AddressablesModExporter.cs, and the public template project
// (github.com/MoSimulator/MoSimulator-Public) does not ship that script. Requiring users
// to add it by hand would mean the app doesn't work on a fresh clone.

const path = require('path');
const fs = require('fs');

const EXPORTER_SCRIPT_REL = ['Assets', 'Editor', 'AddressablesModExporter.cs'];

// Bumped whenever unity/AddressablesModExporter.cs changes, so an older copy already
// sitting in a project gets replaced instead of silently shadowing the new one.
function exporterScriptVersion(source) {
  const match = source.match(/MODBUILDER-SCRIPT-VERSION:\s*(\d+)/);
  return match ? parseInt(match[1], 10) : 0;
}

function bundledExporterScriptPath() {
  return path.join(__dirname, 'unity', 'AddressablesModExporter.cs');
}

// Returns { status: 'current' | 'installed' | 'updated' | 'failed', error? }.
function ensureExporterScriptInstalled(projectPath) {
  let bundled;
  try {
    bundled = fs.readFileSync(bundledExporterScriptPath(), 'utf8');
  } catch (err) {
    return { status: 'failed', error: `couldn't read bundled exporter script: ${err.message}` };
  }

  const target = path.join(projectPath, ...EXPORTER_SCRIPT_REL);
  let existing = null;
  try {
    existing = fs.readFileSync(target, 'utf8');
  } catch { /* not installed yet */ }

  if (existing !== null) {
    // Compare content, not just the version marker: gating purely on the version means
    // any edit that forgets to bump it silently never reaches the project, which is a
    // trap during development and would ship a stale script if a bump were ever missed.
    if (existing === bundled) return { status: 'current' };
    // A newer marker than we carry means some future build of the app installed it -
    // don't downgrade it back.
    if (exporterScriptVersion(existing) > exporterScriptVersion(bundled)) return { status: 'current' };
  }

  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, bundled);
  } catch (err) {
    return { status: 'failed', error: `couldn't install exporter script: ${err.message}` };
  }
  return { status: existing === null ? 'installed' : 'updated' };
}

module.exports = { ensureExporterScriptInstalled, exporterScriptVersion, bundledExporterScriptPath };
