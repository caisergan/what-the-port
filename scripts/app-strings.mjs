// The demo popover's translations come straight from the Mac app's
// Localizable.strings. `node scripts/app-strings.mjs` rewrites
// app/components/appStrings.json; `--check` (run before builds) fails if it's stale.
import { readFileSync, writeFileSync } from 'node:fs'

const LANGUAGES = ['de', 'fr', 'es', 'zh-Hans', 'he', 'ja', 'uk']

// Every app phrase the demo popover shows. English phrases are the keys, as in the app.
const KEYS = [
  'Servers', 'Clean up', 'CPU (servers)', 'CPU (all)',
  'Whole Mac. Click for servers only.', 'Dev servers, as a share of the whole Mac. Click for all.',
  'Other apps', 'Free', '%@ of %@', 'Free · %@', '%@ of RAM', '%@ of RAM · CPU %@',
  'System and smaller apps', 'Everything else', 'Everything else · %@',
  'Pick servers to stop', 'freed by stopping %d', 'Nothing listening', 'Dev servers on ports %d–%d show up here.',
  'Cancel', 'Stop servers', 'Stop %d %@ · free %@', 'server', 'servers', 'servers (few)',
  'Open in browser', 'Stop', 'Back',
  'up %@', 'idle %@', 'Worktree deleted · idle %@', '+%@ in %@',
  'Worktree deleted', 'Idle %@ · no connections', 'Leaking · +%@',
  '<1m', '%dm', '%dh', '%dh %dm', '%dd',
  'Running for %@', 'Restart with the same command', 'Session', 'Branch', 'Folder', 'Framework', 'Command',
  'Started', 'Workspace', 'Session ID', '%d more', 'Less', 'Memory', '10 min', 'Processes',
  'Open localhost:%@', 'Preview',
  'Caches', 'Build caches', 'Other', 'Scanning…', 'Scanned just now', 'Scan again', 'Freed %@', '%d %@',
  'folder', 'folders', 'folders (few)', '%@ · %@. Click to select them all.', 'Server on %@', '%@ worktree',
  'untouched %@', 'used %@ ago', 'Show folders', '%@ · %d folders', '%@ shared', 'Nothing to clean', 'No build caches in %@',
  'Select unused', 'Clear', 'Delete caches', 'Free %@', 'Delete %d %@', 'Web builds', 'Python envs', 'Python caches',
  'Deleted folders are gone for good. Your tools recreate them on the next install or build.',
  'Worktrees', 'Worktree checkouts', 'worktree', 'worktrees', 'worktrees (few)', '%@ in %d %@', '%@ checkout',
  'Show worktrees', 'No build caches', "Worktree checkouts · %@. Removing a worktree frees it; deleting caches doesn't.",
  "Checkouts take %@: the worktrees' own files. Deleting caches leaves them; removing worktrees you no longer need frees them.",
  'Whole worktree', 'Removing the worktree frees %@: its checkout and caches. Its branch stays.',
  "A dev server is running in it on %@, so it's kept.", "%d uncommitted %@, so it's kept. Commit or stash them first.",
  'change', 'changes', 'changes (few)', 'commit', 'commits', 'commits (few)',
  'Untracked files will be deleted: %@', 'Ignored files like .env will be deleted: %@', '%d %@ on no remote. The branch keeps them.',
  'Remove %d %@', 'Remove %d %@ and delete %d %@',
  'Removes %d %@ with git worktree remove: their files are gone for good, their branches stay.',
  'Untracked files in %d %@ will be deleted.', '.env or key files in %d %@ will be deleted.',
  'Commits on no remote in %d %@ stay on their branches.', 'Anything with uncommitted changes is kept.',
  'Select %d %@ untouched for %d days',
  'Worktrees git can remove without losing uncommitted changes. Check the warnings before removing them.',
  'Freed %@ of %@', '%d of %d', 'Cancel %d queued', "Puts the folders that haven't started back in the list.",
]

const unescape = (value) => value.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c))

function read(language) {
  const file = readFileSync(`WhatThePort/Sources/WhatThePort/Resources/${language}.lproj/Localizable.strings`, 'utf8')
  const table = {}
  for (const [, key, value] of file.matchAll(/^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";/gm)) {
    table[unescape(key)] = unescape(value)
  }
  const missing = KEYS.filter((key) => !(key in table))
  if (missing.length) {
    console.error(`app-strings: ${language} has no translation for ${missing.map((k) => JSON.stringify(k)).join(', ')}.`)
    process.exit(1)
  }
  return Object.fromEntries(KEYS.map((key) => [key, table[key]]))
}

const output = 'app/components/appStrings.json'
const json = JSON.stringify(Object.fromEntries(LANGUAGES.map((language) => [language, read(language)])), null, 2) + '\n'

if (process.argv.includes('--check')) {
  if (readFileSync(output, 'utf8') !== json) {
    console.error(`app-strings: ${output} is out of date. Run node scripts/app-strings.mjs.`)
    process.exit(1)
  }
  console.log(`app-strings: ${KEYS.length} phrases match the app.`)
} else {
  writeFileSync(output, json)
  console.log(`app-strings: wrote ${KEYS.length} phrases × ${LANGUAGES.length} languages.`)
}
