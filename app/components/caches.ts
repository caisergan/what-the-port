import { PORT_COLORS } from './servers'

// Sample data for the demo's Build caches page. Keep presentation aligned with
// BuildCachesView.swift. Sizes are binary MB; `size` is on disk and
// `reclaimable` is what deleting frees (pnpm clones share most of theirs).

// Same order as ArtifactKind in BuildCaches.swift, so colours match the app.
export const KINDS = [
  'node_modules', '.next', '.turbo', 'Web builds', 'Rust', 'SwiftPM', 'Xcode',
  'Gradle & Maven', 'CocoaPods', 'Python envs', 'Python caches', 'Caches',
] as const
export type Kind = (typeof KINDS)[number]

export const kindColor = (kind: Kind) => PORT_COLORS[KINDS.indexOf(kind) % PORT_COLORS.length]
// Translated in the app; folder and tool names stay as they are.
const PHRASES: readonly Kind[] = ['Web builds', 'Python envs', 'Python caches', 'Caches']
export const isPhrase = (kind: Kind) => PHRASES.includes(kind)

export type Artifact = { id: string; path: string; kind: Kind; size: number; reclaimable: number; count?: number }

export type CacheProject = {
  name: string
  repository?: string
  /// Port of a demo server running in it.
  port?: string
  /// Minutes since it was last used.
  lastUsed: number
  artifacts: Artifact[]
}

const artifact = (id: string, path: string, kind: Kind, reclaimable: number, size = reclaimable, count?: number): Artifact => ({
  id, path, kind, size, reclaimable, count,
})

export const STALE_DAYS = 14

export const CACHE_PROJECTS: CacheProject[] = [
  {
    name: 'image-pipeline',
    lastUsed: 41 * 1440,
    artifacts: [artifact('image-pipeline/target', 'target', 'Rust', 4710)],
  },
  {
    name: 'ios-app',
    lastUsed: 26 * 60,
    artifacts: [
      artifact('ios-app/build', 'build', 'Xcode', 2960),
      artifact('ios-app/Packages', '.build', 'SwiftPM', 840, 840, 4),
    ],
  },
  {
    name: 'checkout-redesign',
    repository: 'storefront',
    lastUsed: 23 * 1440,
    artifacts: [
      artifact('checkout-redesign/.next', 'apps/web/.next', '.next', 2310),
      artifact('checkout-redesign/node_modules', 'node_modules', 'node_modules', 3, 790, 6),
    ],
  },
  {
    name: 'providence',
    repository: 'what-the-port',
    port: '3000',
    lastUsed: 12,
    artifacts: [
      artifact('providence/.next', '.next', '.next', 1210),
      artifact('providence/node_modules', 'node_modules', 'node_modules', 486),
    ],
  },
  {
    name: 'ml-notebook',
    lastUsed: 64 * 1440,
    artifacts: [
      artifact('ml-notebook/.venv', '.venv', 'Python envs', 1130),
      artifact('ml-notebook/__pycache__', '__pycache__', 'Python caches', 3, 3, 12),
    ],
  },
  {
    name: 'tokens-v2',
    repository: 'design-system',
    port: '6006',
    lastUsed: 3 * 60,
    artifacts: [
      artifact('tokens-v2/node_modules', 'node_modules', 'node_modules', 612),
      artifact('tokens-v2/.turbo', '.turbo', '.turbo', 140),
      artifact('tokens-v2/storybook-static', 'storybook-static', 'Web builds', 96),
    ],
  },
  {
    name: 'lisbon',
    repository: 'paper-plugins',
    port: '5173',
    lastUsed: 50,
    artifacts: [artifact('lisbon/node_modules', 'node_modules', 'node_modules', 540)],
  },
  {
    name: 'tomjohn.design',
    port: '3001',
    lastUsed: 5 * 60,
    artifacts: [
      artifact('tomjohn.design/node_modules', 'node_modules', 'node_modules', 318),
      artifact('tomjohn.design/.astro', '.astro', 'Web builds', 22),
    ],
  },
  {
    name: 'design-system',
    lastUsed: 19 * 1440,
    artifacts: [
      artifact('design-system/.turbo', '.turbo', '.turbo', 210),
      artifact('design-system/node_modules', 'node_modules', 'node_modules', 4, 820, 9),
    ],
  },
]

// A 494 GB Mac with 38 GB free, as Finder counts it.
export const DISK_TOTAL = 494 * 1024
export const DISK_FREE = 38 * 1024

export const reclaimable = (artifacts: Artifact[]) => artifacts.reduce((sum, a) => sum + a.reclaimable, 0)

export const isStale = (project: CacheProject) => project.lastUsed >= STALE_DAYS * 1440

/** What "Select unused" picks: stale projects without a running server. */
export const suggestedCaches = (removed: string[]) =>
  CACHE_PROJECTS.filter((p) => isStale(p) && !p.port)
    .flatMap((p) => p.artifacts)
    .map((a) => a.id)
    .filter((id) => !removed.includes(id))

/** Folder sizes, where a few kilobytes shouldn't read as "0 MB" (Format.diskBytes). */
export function formatDisk(mb: number) {
  if (mb > 0 && mb < 0.5) return '<1 MB'
  return mb >= 1024 ? `${(mb / 1024).toFixed(2)} GB` : `${Math.round(mb)} MB`
}

/** Disks are big: whole gigabytes from 100 GB up. */
export function formatDiskTotal(mb: number) {
  const gb = mb / 1024
  if (gb >= 100) return `${Math.round(gb)} GB`
  return gb >= 1 ? `${Number(gb.toFixed(1))} GB` : `${Math.round(mb)} MB`
}
