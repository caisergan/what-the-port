'use client'

import { type ReactNode, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import styles from './landing.module.css'
import { AMBER, BackIcon, Chevron, ClaudeIcon, CodexIcon, Colon, DotGrid, OpenIcon, VercelIcon } from './icons'
import { type AppLanguageCode, type Localizer, localizer } from './languages'
import { GET_IT, TERMINAL } from './sections'
import {
  type Artifact,
  type Kind,
  CACHE_PROJECTS,
  DISK_FREE,
  DISK_TOTAL,
  KINDS,
  formatDisk,
  formatDiskTotal,
  isPhrase,
  isStale,
  kindColor,
  reclaimable,
  suggestedCaches,
} from './caches'
import {
  type Agent,
  type Server,
  SERVERS,
  OTHER_APPS,
  OTHER_MEMORY,
  SYSTEM_MEMORY,
  cpuBars,
  formatMemory,
  formatTotal,
  memoryChart,
  portColor,
  serverResources,
  stoppedPorts,
} from './servers'

// A working copy of the WhatThePort popover. Scrolling picks the view for each
// section; clicking around works like the real app until the next section.

// A folder in the Build caches deletion queue (BuildCacheStore.CleanupJob).
export type CacheJob = { id: string; state: 'queued' | 'deleting' | 'done' }
const CACHE_ARTIFACTS = CACHE_PROJECTS.flatMap((p) => p.artifacts)
const cacheSize = (id: string) => CACHE_ARTIFACTS.find((a) => a.id === id)?.reclaimable ?? 0

type View = { name: 'list' } | { name: 'detail'; port: string } | { name: 'cleanUp' } | { name: 'caches' }

const SECTION_VIEWS: View[] = [
  { name: 'list' },
  { name: 'detail', port: '3000' },
  { name: 'detail', port: '6006' },
  { name: 'cleanUp' },
  { name: 'list' },
  { name: 'list' },
  { name: 'list' },
]

// The Terminal section shows `wtp` instead, and the last section the dot matrix.
const opensPopover = (section: number) => section !== GET_IT && section !== TERMINAL

const ramShare = (mb: number) => `${((mb / SYSTEM_MEMORY) * 100).toFixed(1)}%`

const suggested = (running: string[]) =>
  SERVERS.filter((s) => s.cleanUp?.suggested && running.includes(s.port)).map((s) => s.port)

export function useDemo(section: number) {
  const [running, setRunning] = useState(() => SERVERS.map((s) => s.port))
  const [view, setView] = useState<View>(SECTION_VIEWS[section])
  const [direction, setDirection] = useState(1)
  const [open, setOpen] = useState(opensPopover(section))
  const [selected, setSelected] = useState(() => suggested(SERVERS.map((s) => s.port)))
  // Build caches: what's been "deleted" and what's ticked, by artifact id.
  const [removedCaches, setRemovedCaches] = useState<string[]>([])
  const [cacheSelection, setCacheSelection] = useState(() => suggestedCaches([]))
  // The simulated deletion queue and how far its current folder has got (0–1).
  const [cacheJobs, setCacheJobs] = useState<CacheJob[]>([])
  const [cacheFraction, setCacheFraction] = useState(0)
  const previous = useRef(section)

  useEffect(() => {
    if (previous.current === section) return
    setDirection(section > previous.current ? 1 : -1)
    previous.current = section
    setView(SECTION_VIEWS[section])
    setOpen(opensPopover(section))
    setSelected(suggested(running))
    setCacheSelection(suggestedCaches(removedCaches))
    // `running` intentionally omitted: stopping a server shouldn't reset the view.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [section])

  const go = useCallback(
    (next: View, dir: number) => {
      setDirection(dir)
      if (next.name === 'cleanUp') setSelected(suggested(running))
      setView(next)
    },
    [running],
  )

  const stop = useCallback((selectedPorts: string[]) => {
    const ports = stoppedPorts(SERVERS, selectedPorts)
    setRunning((current) => current.filter((port) => !ports.includes(port)))
    setSelected((current) => current.filter((port) => !ports.includes(port)))
    setDirection(-1)
    setView((current) => {
      if (current.name === 'detail' && ports.includes(current.port)) {
        return { name: 'list' }
      }
      return current
    })
  }, [])

  const restartAll = useCallback(() => {
    const all = SERVERS.map((s) => s.port)
    setRunning(all)
    setSelected(suggested(all))
  }, [])

  const toggleSelected = useCallback((port: string) => {
    setSelected((current) => (current.includes(port) ? current.filter((p) => p !== port) : [...current, port]))
  }, [])

  // Ticks every id, or clears them all if they already are, like the app's checkboxes.
  const toggleCaches = useCallback((ids: string[]) => {
    setCacheSelection((current) =>
      ids.every((id) => current.includes(id)) ? current.filter((id) => !ids.includes(id)) : [...current, ...ids.filter((id) => !current.includes(id))],
    )
  }, [])

  // Simulated: nothing on the visitor's Mac is touched. Like the app, the
  // folders leave the list at once and are deleted one at a time.
  const deleteCaches = useCallback((ids: string[]) => {
    setRemovedCaches((current) => [...current, ...ids])
    setCacheSelection((current) => current.filter((id) => !ids.includes(id)))
    setCacheJobs((current) => {
      // A finished queue still on screen makes way for the new one.
      const kept = current.every((job) => job.state === 'done') ? [] : current
      const jobs = [...kept, ...ids.map((id): CacheJob => ({ id, state: 'queued' }))]
      if (!jobs.some((job) => job.state === 'deleting')) {
        const next = jobs.findIndex((job) => job.state === 'queued')
        jobs[next] = { ...jobs[next], state: 'deleting' }
      }
      return jobs
    })
  }, [])

  // Folders that haven't started go back in the list.
  const cancelQueuedCaches = useCallback(() => {
    const queued = cacheJobs.filter((job) => job.state === 'queued').map((job) => job.id)
    setCacheJobs((current) => current.filter((job) => job.state !== 'queued'))
    setRemovedCaches((current) => current.filter((id) => !queued.includes(id)))
  }, [cacheJobs])

  const restoreCaches = useCallback(() => {
    setRemovedCaches([])
    setCacheSelection(suggestedCaches([]))
    setCacheJobs([])
  }, [])

  // Works through the queue: about a second and a half per gigabyte.
  const deleting = cacheJobs.find((job) => job.state === 'deleting')?.id
  const finished = cacheJobs.length > 0 && cacheJobs.every((job) => job.state === 'done')
  useEffect(() => {
    if (!deleting) return
    const step = 100 / Math.max(500, (cacheSize(deleting) / 1024) * 1500)
    const timer = setInterval(() => setCacheFraction((fraction) => Math.min(fraction + step, 1)), 100)
    return () => clearInterval(timer)
  }, [deleting])

  useEffect(() => {
    if (!deleting || cacheFraction < 1) return
    setCacheJobs((current) => {
      const jobs = current.map((job): CacheJob => (job.id === deleting ? { ...job, state: 'done' } : job))
      const next = jobs.findIndex((job) => job.state === 'queued')
      if (next >= 0) jobs[next] = { ...jobs[next], state: 'deleting' }
      return jobs
    })
    setCacheFraction(0)
  }, [deleting, cacheFraction])

  // The result stays up for a moment, as in the app.
  useEffect(() => {
    if (!finished) return
    const timer = setTimeout(() => setCacheJobs([]), 6000)
    return () => clearTimeout(timer)
  }, [finished])

  // A detail view for a server that's been stopped falls back to the list.
  const shown: View = view.name === 'detail' && !running.includes(view.port) ? { name: 'list' } : view

  return {
    running: SERVERS.filter((s) => running.includes(s.port)),
    view: shown,
    direction,
    open,
    setOpen,
    selected,
    toggleSelected,
    go,
    stop,
    restartAll,
    removedCaches,
    cacheSelection,
    setCacheSelection,
    toggleCaches,
    deleteCaches,
    restoreCaches,
    cacheJobs,
    cacheFraction,
    cancelQueuedCaches,
  }
}

export type Demo = ReturnType<typeof useDemo>

// Keeps the popover's height animating between views, the way a macOS popover resizes.
function Frame({ children, viewKey }: { children: ReactNode; viewKey: string }) {
  const innerRef = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState<number>()

  useLayoutEffect(() => {
    const inner = innerRef.current
    if (!inner) return
    const measure = () => setHeight(inner.offsetHeight)
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(inner)
    return () => observer.disconnect()
  }, [viewKey])

  return (
    <div className={styles.popover} style={{ height }}>
      <div ref={innerRef}>{children}</div>
    </div>
  )
}

// `language` shows the app's own translations, laid out right-to-left for Hebrew.
export function AppPopover({ demo, language = 'en' }: { demo: Demo; language?: AppLanguageCode }) {
  const { view, direction } = demo
  const l = localizer(language)
  const key =
    view.name === 'detail'
      ? `detail-${view.port}`
      : view.name === 'caches'
        ? 'caches'
        : demo.running.length
        ? view.name === 'cleanUp'
          ? 'list'
          : view.name
        : 'empty'

  let content: ReactNode
  if (view.name === 'detail') content = <DetailView demo={demo} server={SERVERS.find((s) => s.port === view.port)!} l={l} />
  else if (view.name === 'caches') content = <CachesView demo={demo} l={l} />
  else content = <ListView demo={demo} l={l} />

  return (
    <Frame viewKey={key}>
      <div
        key={key}
        className={styles.view}
        style={{ ['--dir' as string]: direction }}
        lang={language}
        dir={l.rtl ? 'rtl' : 'ltr'}
      >
        {content}
      </div>
    </Frame>
  )
}

function Header({ title, onBack, backLabel }: { title: string; onBack?: () => void; backLabel?: string }) {
  return (
    <div className={styles.popTitleRow}>
      <span className={styles.popTitle}>{title}</span>
      {onBack && (
        <button type="button" className={styles.popBack} onClick={onBack} aria-label={backLabel}>
          <BackIcon />
        </button>
      )}
    </div>
  )
}

function AgentIcon({ agent }: { agent?: Agent }) {
  if (agent === 'claude') return <ClaudeIcon />
  if (agent === 'codex') return <CodexIcon />
  return null
}

// Brief confirmation on buttons that would open something outside the demo.
function useFlash() {
  const [flash, setFlash] = useState<string | null>(null)
  const timer = useRef<ReturnType<typeof setTimeout>>()
  useEffect(() => () => clearTimeout(timer.current), [])
  const trigger = useCallback((id: string) => {
    setFlash(id)
    clearTimeout(timer.current)
    timer.current = setTimeout(() => setFlash(null), 1400)
  }, [])
  return [flash, trigger] as const
}

function ListView({ demo, l }: { demo: Demo; l: Localizer }) {
  const [flash, trigger] = useFlash()
  const cleaning = demo.view.name === 'cleanUp'
  const [focus, setFocus] = useState<string | null>(null)
  const [hoveredRow, setHoveredRow] = useState<string | null>(null)
  const [cpuAll, setCpuAll] = useState(false)
  const resources = serverResources(demo.running)
  const total = resources.memory
  const cpu = Math.round(resources.cpu / 8)
  const cleanUpCount = demo.running.filter((s) => s.cleanUp?.suggested).length
  const cachesLeft = reclaimable(
    CACHE_PROJECTS.flatMap((p) => p.artifacts).filter((a) => !demo.removedCaches.includes(a.id)),
  )
  const chosen = demo.running.filter((s) => demo.selected.includes(s.port))
  const freed = serverResources(chosen).memory
  const focusedServer = demo.running.find((s) => s.port === focus)
  const focusedApp = OTHER_APPS.find((app) => app.id === focus)
  const focusedMemory = focusedServer?.memory ?? focusedApp?.memory
  const [value, unit] = (
    focusedServer ? formatMemory(focusedServer.memory) : formatTotal(focusedMemory ?? (cleaning ? freed : total))
  ).split(' ')
  const activePort = focus ?? hoveredRow
  const activate = (port: string) => {
    if (cleaning) demo.toggleSelected(port)
    else {
      setFocus(null)
      demo.go({ name: 'detail', port }, 1)
    }
  }

  return (
    <>
      <div className={styles.popHead}>
        <Header
          title={
            focusedServer
              ? `${focusedServer.name} :${focusedServer.port}`
              : (focusedApp?.id === 'rest' ? l.text('Everything else') : (focusedApp?.name ?? l.text(cleaning ? 'Clean up' : 'Servers')))
          }
        />
        <div className={styles.popDisplay}>
          <span className={styles.popBig}>{value}</span>
          <span className={styles.popUnit}>{unit}</span>
          <span className={styles.summaryDetail}>
            {focusedMemory !== undefined ? (
              <span className={focusedApp?.id === 'rest' ? styles.t2 : styles.mono}>
                {focusedApp?.id === 'rest'
                  ? l.text('System and smaller apps')
                  : focusedServer
                    ? l.format('%@ of RAM · CPU %@', ramShare(focusedMemory), `${focusedServer.cpu}%`)
                    : l.format('%@ of RAM', ramShare(focusedMemory))}
              </span>
            ) : cleaning ? (
              <span className={styles.t2}>
                {chosen.length ? l.format('freed by stopping %d', chosen.length) : l.text('Pick servers to stop')}
              </span>
            ) : (
              <button
                type="button"
                className={styles.cpuToggle}
                onClick={() => setCpuAll((v) => !v)}
                title={l.text(
                  cpuAll ? 'Whole Mac. Click for servers only.' : 'Dev servers, as a share of the whole Mac. Click for all.',
                )}
              >
                <span className={styles.t3}>{l.text(cpuAll ? 'CPU (all)' : 'CPU (servers)')}</span>
                <span className={`${styles.mono} ${styles.t2}`}>{cpuAll ? cpu + 18 : cpu}%</span>
              </button>
            )}
          </span>
        </div>
        <div className={styles.shareBar} aria-label="Mac memory usage">
          {demo.running.map((s) => (
            <button
              key={s.port}
              type="button"
              className={styles.memorySegment}
              style={{ flexGrow: resources.memoryByPort.get(s.port) ?? 0, color: portColor(s.port) }}
              data-raised
              data-focused={activePort === s.port}
              data-dim={
                (activePort !== null && activePort !== s.port) ||
                (cleaning && !demo.selected.includes(s.port) && activePort !== s.port)
              }
              aria-label={`${s.name} :${s.port} · ${formatMemory(s.memory)}`}
              aria-pressed={cleaning ? demo.selected.includes(s.port) : undefined}
              onMouseEnter={() => setFocus(s.port)}
              onMouseLeave={() => setFocus(null)}
              onFocus={() => setFocus(s.port)}
              onBlur={() => setFocus(null)}
              onClick={() => activate(s.port)}
            />
          ))}
          {OTHER_APPS.map((app) => (
            <span
              key={app.id}
              className={styles.memorySegment}
              style={{ flexGrow: app.memory }}
              tabIndex={0}
              role="img"
              aria-label={app.id === 'rest' ? l.format('Everything else · %@', formatMemory(app.memory)) : `${app.name} · ${formatMemory(app.memory)}`}
              data-focused={focus === app.id}
              onMouseEnter={() => setFocus(app.id)}
              onMouseLeave={() => setFocus(null)}
              onFocus={() => setFocus(app.id)}
              onBlur={() => setFocus(null)}
            />
          ))}
          <span
            className={styles.freeMemory}
            style={{ flexGrow: SYSTEM_MEMORY - total - OTHER_MEMORY }}
            title={l.format('Free · %@', formatMemory(SYSTEM_MEMORY - total - OTHER_MEMORY))}
          />
        </div>
        <div className={styles.memoryLegend}>
          <span>
            <i data-servers />
            {l.text('Servers')} <b>{formatTotal(total)}</b>
          </span>
          <span>
            <i />
            {l.text('Other apps')} <b>{formatTotal(OTHER_MEMORY)}</b>
          </span>
          <span>
            <i data-free />
            {l.text('Free')} <b>{l.format('%@ of %@', formatTotal(SYSTEM_MEMORY - total - OTHER_MEMORY).split(' ')[0], '16 GB')}</b>
          </span>
        </div>
      </div>

      <div className={`${styles.popSection} ${styles.rowList}`}>
        {!demo.running.length && (
          <div className={styles.emptyState}>
            <DotGrid size={48} />
            <span className={styles.t2}>{l.text('Nothing listening')}</span>
            <span className={`${styles.caption} ${styles.t3}`}>
              {l.format('Dev servers on ports %d–%d show up here.', 3000, 65535)}
            </span>
          </div>
        )}
        {demo.running.map((s) => (
          <div
            key={s.port}
            role="button"
            tabIndex={0}
            className={styles.serverRow}
            data-interactive
            data-dim={s.status === 'idle' || (focus !== null && focus !== s.port)}
            data-focused={focus === s.port}
            data-cleaning={cleaning}
            aria-pressed={cleaning ? demo.selected.includes(s.port) : undefined}
            aria-label={`${cleaning ? 'Select' : 'View'} ${s.branch} on port ${s.port}`}
            onMouseEnter={() => setHoveredRow(s.port)}
            onMouseLeave={() => setHoveredRow(null)}
            onClick={() => activate(s.port)}
            onKeyDown={(e) => {
              if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) {
                e.preventDefault()
                activate(s.port)
              }
            }}
          >
            {cleaning && (
              <span className={styles.checkbox} data-checked={demo.selected.includes(s.port)} aria-hidden>
                <svg width="10" height="10" viewBox="0 0 10 10">
                  <path
                    d="M2 5.2 4.1 7.3 8 2.8"
                    fill="none"
                    stroke="#0B0D12"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </span>
            )}
            <span className={styles.portLabel}>
              <Colon state={s.status} color={portColor(s.port)} />
              <span className={styles.rowPort} style={{ color: portColor(s.port) }}>
                {s.port}
              </span>
            </span>
            <span className={styles.rowMain}>
              <span className={styles.rowName} title={s.branch}>
                {s.branch.replaceAll('-', ' ')}
              </span>
              <span className={styles.rowSub} style={{ color: s.context.tone === 'amber' ? AMBER : '#EBEBF599' }}>
                {cleaning && s.cleanUp ? REASON_ICONS[s.cleanUp.reason] : <AgentIcon agent={s.context.agent} />}
                <span className={styles.ellipsis}>
                  {flash === s.port
                    ? `Opened localhost:${s.port}`
                    : cleaning && s.cleanUp
                      ? s.lines(l).note
                      : s.lines(l).context}
                </span>
              </span>
            </span>
            <svg className={styles.rowSpark} width="40" height="18" viewBox="0 0 44 18" aria-hidden>
              <path
                d={s.spark}
                fill="none"
                stroke={s.status === 'amber' ? AMBER : `rgb(245 245 247 / ${s.status === 'idle' ? 50 : 70}%)`}
                strokeWidth={s.status === 'amber' ? 1.5 : 1.25}
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeDasharray={s.status === 'idle' ? '2 3' : undefined}
              />
            </svg>
            {!cleaning && (
              <span className={styles.rowActions}>
                <button
                  type="button"
                  className={styles.rowAction}
                  aria-label={l.text('Open in browser')}
                  onClick={(e) => {
                    e.stopPropagation()
                    trigger(s.port)
                  }}
                >
                  <OpenIcon />
                </button>
                <button
                  type="button"
                  className={styles.rowAction}
                  aria-label={l.text('Stop')}
                  onClick={(e) => {
                    e.stopPropagation()
                    demo.stop([s.port])
                  }}
                >
                  <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
                    <rect x="2.5" y="2.5" width="7" height="7" rx="1.5" fill="rgb(245 245 247 / 80%)" />
                  </svg>
                </button>
              </span>
            )}
            <span className={styles.rowMemory} style={{ color: s.status === 'amber' ? AMBER : undefined }}>
              {formatMemory(s.memory)}
            </span>
          </div>
        ))}
      </div>

      {!demo.running.length ? (
        <div className={`${styles.popSection} ${styles.actions}`}>
          <button type="button" className={styles.primaryAction} onClick={demo.restartAll}>
            Start the demo servers again
          </button>
        </div>
      ) : cleaning ? (
        <div className={`${styles.popSection} ${styles.actions}`}>
          <button type="button" className={styles.secondaryAction} onClick={() => demo.go({ name: 'list' }, -1)}>
            {l.text('Cancel')}
          </button>
          <button
            type="button"
            className={`${styles.primaryAction} ${styles.destructive}`}
            disabled={!chosen.length}
            onClick={() => {
              demo.stop(chosen.map((s) => s.port))
              demo.go({ name: 'list' }, -1)
            }}
          >
            {chosen.length
              ? l.format('Stop %d %@ · free %@', chosen.length, l.counted('server', 'servers', chosen.length), formatMemory(freed))
              : l.text('Stop servers')}
          </button>
        </div>
      ) : (
        <div className={`${styles.popSection} ${styles.popFooter}`}>
          <button type="button" className={styles.chip} onClick={() => demo.go({ name: 'cleanUp' }, 1)}>
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
              <path
                d="M8.5 1.5 6 7M3 8.5h7l.8 4H2.2L3 8.5Z"
                fill="none"
                stroke="#F5F5F7"
                strokeWidth="1.3"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <path d="M5 10.5v2M7.5 10.5v2" fill="none" stroke="#F5F5F7" strokeWidth="1.1" strokeLinecap="round" />
            </svg>
            <span className={styles.popTitle}>{l.text('Clean up')}</span>
            {cleanUpCount > 0 && <span className={styles.chipCount}>{cleanUpCount}</span>}
          </button>
          <button
            type="button"
            className={`${styles.chip} ${styles.cachesChip}`}
            title={l.text('Build caches')}
            onClick={() => demo.go({ name: 'caches' }, 1)}
          >
            <BoxIcon />
            <span className={styles.popTitle}>{l.text('Caches')}</span>
            {cachesLeft > 0 && <span className={styles.chipCount}>{formatTotal(cachesLeft)}</span>}
          </button>
          <span className={styles.footerSpacer} />
          <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden>
            <path
              d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"
              fill="none"
              stroke="rgb(235 235 245 / 70%)"
              strokeWidth="1.9"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
            <circle cx="12" cy="12" r="3" fill="none" stroke="rgb(235 235 245 / 70%)" strokeWidth="1.9" />
          </svg>
        </div>
      )}
    </>
  )
}

function DetailView({ demo, server, l }: { demo: Demo; server: Server; l: Localizer }) {
  const [moreInfo, setMoreInfo] = useState(false)
  const [processesOpen, setProcessesOpen] = useState(false)
  const [restarting, setRestarting] = useState(false)
  const [restarted, setRestarted] = useState(false)
  const [flash, trigger] = useFlash()
  const [hover, setHover] = useState<number | null>(null)
  const memory = memoryChart(server)
  const bars = cpuBars(server)
  const sample = hover === null ? null : memory.points[Math.round(hover * (memory.points.length - 1))]
  const cpuSample = hover === null ? server.cpu : bars[Math.round(hover * (bars.length - 1))]
  const timestamp =
    hover === null
      ? null
      : `13:${String(14 + Math.floor(hover * 10)).padStart(2, '0')}:${String(Math.floor(hover * 600) % 60).padStart(2, '0')}`
  const chartHover = (event: React.MouseEvent<SVGSVGElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect()
    setHover(Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width)))
  }

  useEffect(() => {
    if (!restarting) return
    const timer = setTimeout(() => {
      setRestarting(false)
      setRestarted(true)
    }, 900)
    return () => clearTimeout(timer)
  }, [restarting])

  const shownInfo: [string, ReactNode][] = server.session
    ? [
        [
          'Session',
          <span key="session" className={styles.infoValue}>
            <AgentIcon agent={server.session.agent} />
            <span className={`${styles.ellipsis} ${styles.t1}`}>{server.session.title}</span>
            <span style={{ flexGrow: 1 }} />
            <OpenIcon color="rgb(235 235 245 / 60%)" />
          </span>,
        ],
        ['Branch', server.branch],
      ]
    : [
        ['Branch', server.branch],
        ['Folder', server.info[0][1]],
      ]
  const hiddenInfo: [string, string][] = server.info
    .filter(([label]) => !(label === 'Folder' && !server.session) && label !== 'PID' && label !== 'Git')
  if (server.session) hiddenInfo.push(['Session ID', server.session.id])

  return (
    <>
      <div className={styles.popHead}>
        <Header title={server.name} onBack={() => demo.go({ name: 'list' }, -1)} backLabel={l.text('Back')} />
        <div className={styles.popDisplay} style={{ justifyContent: 'space-between' }}>
          <span className={styles.popDisplay} dir="ltr">
            <Colon state={server.status} color={portColor(server.port)} dot={6} gap={6} />
            <span className={styles.popBig} style={{ color: portColor(server.port) }}>
              {server.port}
            </span>
          </span>
          <span className={styles.popDisplay} style={{ gap: 10 }}>
            <span className={styles.t3}>
              {restarting
                ? 'restarting…'
                : restarted
                  ? l.format('Running for %@', l.duration(0))
                  : l.format('Running for %@', server.lines(l).running)}
            </span>
            <span className={styles.popDisplay}>
              <button
                type="button"
                className={styles.control}
                aria-label="Restart"
                disabled={server.status === 'idle' || restarting}
                title={
                  server.status === 'idle' ? 'Working directory no longer exists' : l.text('Restart with the same command')
                }
                data-spinning={restarting}
                onClick={() => setRestarting(true)}
              >
                <svg width="13" height="13" viewBox="0 0 14 14" aria-hidden>
                  <path
                    d="M11.5 7a4.5 4.5 0 1 1-1.3-3.2"
                    fill="none"
                    stroke="#F5F5F7"
                    strokeWidth="1.4"
                    strokeLinecap="round"
                  />
                  <path
                    d="M10.6 1.6v2.6H8"
                    fill="none"
                    stroke="#F5F5F7"
                    strokeWidth="1.4"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </button>
              <button
                type="button"
                className={`${styles.control} ${styles.controlStop}`}
                aria-label={l.text('Stop')}
                onClick={() => demo.stop([server.port])}
              >
                <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden>
                  <rect x="2" y="2" width="8" height="8" rx="1.8" fill="#FF6961" />
                </svg>
              </button>
            </span>
          </span>
        </div>
      </div>

      <div className={`${styles.popSection} ${styles.infoList}`}>
        {shownInfo.map(([label, value]) => (
          <div key={label} className={styles.infoRow}>
            <span className={styles.infoLabel}>{l.text(label)}</span>
            {typeof value === 'string' ? <span className={`${styles.ellipsis} ${styles.t1}`}>{value}</span> : value}
          </div>
        ))}
        <div className={styles.collapsible} data-open={moreInfo}>
          <div>
            {hiddenInfo.map(([label, value]) => (
              <div key={label} className={styles.infoRow}>
                <span className={styles.infoLabel}>{l.text(label)}</span>
                <span
                  className={`${styles.ellipsis} ${label === 'PID' || label === 'Command' ? styles.mono : ''} ${styles.t1}`}
                >
                  {value}
                </span>
              </div>
            ))}
          </div>
        </div>
        <div className={styles.infoRow}>
          <span className={styles.infoLabel} />
          <button type="button" className={styles.infoMore} onClick={() => setMoreInfo((v) => !v)} data-open={moreInfo}>
            {moreInfo ? l.text('Less') : l.format('%d more', hiddenInfo.length)} <Chevron direction="down" />
          </button>
        </div>
      </div>

      <div className={`${styles.popSection} ${styles.chart}`}>
        <div className={styles.chartHead}>
          <span className={styles.chartTitle}>
            <span className={styles.t2}>{l.text('Memory')}</span>
            <span className={styles.mono} style={{ fontWeight: 500 }}>
              {formatMemory(sample?.memory ?? server.memory)}
            </span>
          </span>
          <span className={`${styles.mono} ${styles.caption} ${styles.t3}`}>{timestamp ?? l.text('10 min')}</span>
        </div>
        <div className={styles.plot}>
          <span className={styles.axis} style={{ height: 56, position: 'relative' }}>
            <span style={{ position: 'absolute', top: memory.limit - 7, color: '#FFB224D9' }}>2 GB</span>
            <span style={{ position: 'absolute', bottom: -6 }}>0</span>
          </span>
          <svg
            width="328"
            height="56"
            viewBox="0 0 328 56"
            role="img"
            aria-label="Memory over the last ten minutes"
            style={{ flexShrink: 0 }}
            onMouseMove={chartHover}
            onMouseLeave={() => setHover(null)}
          >
            <path d="M0.5 0 V56 M0 55.5 H328" fill="none" stroke="rgb(255 255 255 / 14%)" />
            <path d={`M0 ${memory.limit} H328`} fill="none" stroke="rgb(255 178 36 / 55%)" strokeDasharray="3 3" />
            <path
              className={styles.chartLine}
              d={memory.line}
              fill="none"
              stroke="rgb(245 245 247 / 90%)"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              pathLength={1}
            />
            {sample && <path d={`M${sample.x} 0 V56`} stroke="#F5F5F740" />}
            <circle cx={sample?.x ?? 327} cy={sample?.y ?? memory.end} r="3" fill="#F5F5F7" />
          </svg>
        </div>
      </div>

      <div className={styles.chart} style={{ paddingTop: 0 }}>
        <div className={styles.chartHead}>
          <span className={styles.chartTitle}>
            <span className={styles.t2}>CPU</span>
            <span className={styles.mono} style={{ fontWeight: 500 }}>
              {Math.round(cpuSample)}%
            </span>
          </span>
          {timestamp && <span className={`${styles.mono} ${styles.caption} ${styles.t3}`}>{timestamp}</span>}
        </div>
        <div className={styles.plot}>
          <span className={styles.axis} style={{ height: 56 }}>
            <span style={{ marginTop: -6 }}>100%</span>
            <span style={{ marginBottom: -6 }}>0</span>
          </span>
          <svg
            width="328"
            height="56"
            viewBox="0 0 328 56"
            role="img"
            aria-label="CPU over the last ten minutes"
            style={{ flexShrink: 0 }}
            onMouseMove={chartHover}
            onMouseLeave={() => setHover(null)}
          >
            <path d="M0.5 0 V56 M0 55.5 H328" fill="none" stroke="rgb(255 255 255 / 14%)" />
            {bars.map((cpu, i) => (
              <rect
                key={i}
                className={styles.cpuBar}
                style={{ animationDelay: `${i * 6}ms` }}
                x={0.5 + i * 5.4627}
                y={56 - Math.max(0.6, cpu * 0.56)}
                width="3"
                height={Math.max(0.6, cpu * 0.56)}
                rx="1"
                fill={i === Math.round((hover ?? 1) * (bars.length - 1)) ? '#F5F5F7D9' : '#F5F5F752'}
              />
            ))}
            {hover !== null && <path d={`M${hover * 328} 0 V56`} stroke="#F5F5F740" />}
          </svg>
        </div>
      </div>

      <div className={styles.popSection}>
        <button
          type="button"
          className={styles.processes}
          onClick={() => setProcessesOpen((v) => !v)}
          aria-expanded={processesOpen}
          data-open={processesOpen}
        >
          <span className={styles.popDisplay} style={{ gap: 4 }}>
            <span className={styles.t2}>{l.text('Processes')}</span>
            <span className={styles.processesChevron}>
              <Chevron direction="right" />
            </span>
          </span>
          <span className={styles.popDisplay} style={{ gap: 8 }}>
            <span className={`${styles.mono} ${styles.t3}`}>{server.processes.length} ·</span>
            <span className={`${styles.mono} ${styles.t2}`}>{formatMemory(server.memory)}</span>
          </span>
        </button>
        <div className={styles.collapsible} data-open={processesOpen}>
          <div>
            <div className={styles.processList}>
              {server.processes.map((p, index) => (
                <div key={p.command} className={styles.processRow}>
                  <span className={`${styles.mono} ${styles.ellipsis} ${styles.t1}`}>
                    {index ? '└ ' : ''}
                    {p.command}
                  </span>
                  <span className={styles.processBar}>
                    <i style={{ width: `${(p.memory / Math.max(...server.processes.map((p) => p.memory))) * 100}%` }} />
                  </span>
                  <span className={`${styles.mono} ${styles.t2}`}>{formatMemory(p.memory)}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      <div className={`${styles.popSection} ${styles.actions}`}>
        <button type="button" className={styles.primaryAction} onClick={() => trigger('open')}>
          {flash === 'open' ? 'Opened in your browser' : l.format('Open localhost:%@', server.port)}
        </button>
        <button type="button" className={styles.secondaryAction} onClick={() => trigger('preview')}>
          <VercelIcon fill="rgb(235 235 245 / 75%)" width={11} height={10} />
          {flash === 'preview' ? 'Opened' : l.text('Preview')}
        </button>
        <button type="button" className={styles.moreAction} aria-label="More">
          <span />
          <span />
          <span />
        </button>
      </div>
    </>
  )
}

function BoxIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
      <path
        d="M7 1.6 12.2 4.2v5.6L7 12.4 1.8 9.8V4.2L7 1.6ZM1.8 4.2 7 6.8l5.2-2.6M7 6.8v5.6M4.4 2.9l5.2 2.6"
        fill="none"
        stroke="#F5F5F7"
        strokeWidth="1.15"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function Check({ state, small }: { state: 'on' | 'off' | 'mixed'; small?: boolean }) {
  return (
    <span className={styles.checkbox} data-checked={state !== 'off'} data-small={small} aria-hidden>
      <svg width="10" height="10" viewBox="0 0 10 10">
        <path
          d={state === 'mixed' ? 'M2.6 5h4.8' : 'M2 5.2 4.1 7.3 8 2.8'}
          fill="none"
          stroke="#0B0D12"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  )
}

const checkState = (artifacts: Artifact[], selection: string[]) => {
  const count = artifacts.filter((a) => selection.includes(a.id)).length
  return count === 0 ? 'off' : count === artifacts.length ? 'on' : 'mixed'
}

// Build caches: like BuildCachesView.swift. Deleting is simulated.
function CachesView({ demo, l }: { demo: Demo; l: Localizer }) {
  const [focus, setFocus] = useState<Kind | null>(null)
  const [hoveredRow, setHoveredRow] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string[]>([])
  const [confirming, setConfirming] = useState(false)
  const [scanning, setScanning] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>()
  useEffect(() => () => clearTimeout(timer.current), [])

  const label = (kind: Kind) => (isPhrase(kind) ? l.text(kind) : kind)
  const projects = CACHE_PROJECTS.map((p) => ({
    ...p,
    artifacts: p.artifacts.filter((a) => !demo.removedCaches.includes(a.id)).sort((a, b) => b.reclaimable - a.reclaimable),
  }))
    .filter((p) => p.artifacts.length)
    .sort((a, b) => reclaimable(b.artifacts) - reclaimable(a.artifacts))
  const artifacts = projects.flatMap((p) => p.artifacts)
  const total = reclaimable(artifacts)
  const removedMb = reclaimable(CACHE_PROJECTS.flatMap((p) => p.artifacts).filter((a) => demo.removedCaches.includes(a.id)))
  const jobs = demo.cacheJobs
  const jobMb = (state: CacheJob['state']) => reclaimable(CACHE_ARTIFACTS.filter((a) => jobs.some((j) => j.id === a.id && j.state === state)))
  const deletingMb = jobMb('deleting')
  const running = jobs.some((j) => j.state !== 'done')
  const freedMb = jobMb('done') + deletingMb * demo.cacheFraction
  const queueMb = jobMb('done') + deletingMb + jobMb('queued')
  // Like the app, free space grows as each folder finishes.
  const free = DISK_FREE + removedMb - deletingMb - jobMb('queued')
  const other = DISK_TOTAL - free - total
  const kinds = KINDS.map((kind) => ({ kind, mb: reclaimable(artifacts.filter((a) => a.kind === kind)) }))
    .filter((k) => k.mb > 0)
    .sort((a, b) => b.mb - a.mb)
  const selected = artifacts.filter((a) => demo.cacheSelection.includes(a.id))
  const selectedMb = reclaimable(selected)
  const selectedFolders = selected.reduce((sum, a) => sum + (a.count ?? 1), 0)
  const suggestion = suggestedCaches(demo.removedCaches)
  const lit = hoveredRow ? new Set(projects.find((p) => p.name === hoveredRow)?.artifacts.map((a) => a.kind)) : null
  const [value, unit] = formatTotal(focus ? reclaimable(artifacts.filter((a) => a.kind === focus)) : total).split(' ')
  const focusCount = focus ? artifacts.filter((a) => a.kind === focus).length : 0

  const rescan = () => {
    setScanning(true)
    clearTimeout(timer.current)
    timer.current = setTimeout(() => setScanning(false), 1200)
  }
  const confirmDelete = () => {
    demo.deleteCaches(selected.map((a) => a.id))
    setConfirming(false)
  }

  return (
    <>
      <div className={styles.popHead}>
        {focus ? (
          <div className={styles.popTitleRow}>
            <span className={styles.kindTitle}>
              <i style={{ background: kindColor(focus) }} />
              <span className={styles.popTitle}>{label(focus)}</span>
            </span>
          </div>
        ) : (
          <Header title={l.text('Build caches')} onBack={() => demo.go({ name: 'list' }, -1)} backLabel={l.text('Back')} />
        )}
        <div className={styles.popDisplay}>
          <span className={styles.popBig}>{value}</span>
          <span className={styles.popUnit}>{unit}</span>
          <span className={styles.summaryDetail}>
            {focus ? (
              <span className={styles.t2}>{l.format('%d %@', focusCount, l.counted('folder', 'folders', focusCount))}</span>
            ) : running ? (
              <span className={`${styles.cleanupStatus} ${styles.t2}`}>
                <ProgressRing fraction={queueMb ? freedMb / queueMb : 0} />
                {l.format('Freed %@ of %@', formatDisk(freedMb), formatDisk(queueMb))}
              </span>
            ) : scanning ? (
              <span className={styles.t2}>{l.text('Scanning…')}</span>
            ) : jobs.length ? (
              <span className={styles.t2}>✓ {l.format('Freed %@', formatDisk(freedMb))}</span>
            ) : (
              <button type="button" className={styles.cpuToggle} onClick={rescan} title={l.text('Scan again')}>
                <span className={styles.t3}>{l.text('Scanned just now')}</span>
                <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden>
                  <path
                    d="M10 6a4 4 0 1 1-1.2-2.85M10 1.8v2.6H7.4"
                    fill="none"
                    stroke="rgb(235 235 245 / 60%)"
                    strokeWidth="1.3"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </button>
            )}
          </span>
        </div>
        <div className={styles.shareBar} aria-label="Disk usage">
          {kinds.map(({ kind, mb }) => (
            <button
              key={kind}
              type="button"
              className={styles.memorySegment}
              style={{ flexGrow: mb, color: kindColor(kind) }}
              data-raised
              data-focused={focus === kind}
              data-dim={(focus !== null && focus !== kind) || (lit !== null && !lit.has(kind))}
              aria-label={l.format('%@ · %@. Click to select them all.', label(kind), formatDisk(mb))}
              title={l.format('%@ · %@. Click to select them all.', label(kind), formatDisk(mb))}
              onMouseEnter={() => setFocus(kind)}
              onMouseLeave={() => setFocus(null)}
              onFocus={() => setFocus(kind)}
              onBlur={() => setFocus(null)}
              onClick={() => demo.toggleCaches(artifacts.filter((a) => a.kind === kind).map((a) => a.id))}
            />
          ))}
          <span
            className={styles.memorySegment}
            style={{ flexGrow: other }}
            title={l.format('Everything else · %@', formatDiskTotal(other))}
          />
          <span className={styles.freeMemory} style={{ flexGrow: free }} title={l.format('Free · %@', formatDiskTotal(free))} />
        </div>
        <div className={styles.memoryLegend}>
          <span>
            <i data-servers />
            {l.text('Caches')} <b>{formatTotal(total)}</b>
          </span>
          <span className={styles.legendShrink}>
            <i />
            {l.text('Other')} <b>{formatDiskTotal(other)}</b>
          </span>
          <span>
            <i data-free />
            {l.text('Free')} <b>{l.format('%@ of %@', formatDiskTotal(free).split(' ')[0], formatDiskTotal(DISK_TOTAL))}</b>
          </span>
        </div>
        {jobs.length > 0 && <CleanupCard demo={demo} l={l} freedMb={freedMb} />}
      </div>

      <div className={`${styles.popSection} ${styles.rowList} ${styles.cacheList}`}>
        {!projects.length && (
          <div className={styles.emptyState}>
            <DotGrid size={48} />
            <span className={styles.t2}>{l.text('Nothing to clean')}</span>
            <span className={`${styles.caption} ${styles.t3}`}>{l.format('No build caches in %@', '~/Code')}</span>
          </div>
        )}
        {projects.map((project) => {
          const open = expanded.includes(project.name)
          const kindTotals = KINDS.map((kind) => ({ kind, mb: reclaimable(project.artifacts.filter((a) => a.kind === kind)) }))
            .filter((k) => project.artifacts.some((a) => a.kind === k.kind))
            .sort((a, b) => b.mb - a.mb)
            .map((k) => label(k.kind))
          const kindText = kindTotals.length > 3 ? `${kindTotals.slice(0, 2).join(', ')} +${kindTotals.length - 2}` : kindTotals.join(', ')
          const age = isStale(project)
            ? l.format('untouched %@', l.duration(project.lastUsed, true))
            : l.format('used %@ ago', l.duration(project.lastUsed, true))
          const toggle = () => demo.toggleCaches(project.artifacts.map((a) => a.id))
          return (
            <div
              key={project.name}
              className={styles.cacheProject}
              data-dim={focus !== null && !project.artifacts.some((a) => a.kind === focus)}
              onMouseEnter={() => setHoveredRow(project.name)}
              onMouseLeave={() => setHoveredRow(null)}
            >
              <div
                role="button"
                tabIndex={0}
                className={styles.serverRow}
                data-interactive
                aria-pressed={checkState(project.artifacts, demo.cacheSelection) === 'on'}
                aria-label={`Select caches in ${project.name}`}
                onClick={toggle}
                onKeyDown={(e) => {
                  if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) {
                    e.preventDefault()
                    toggle()
                  }
                }}
              >
                <Check state={checkState(project.artifacts, demo.cacheSelection)} />
                <span className={styles.rowMain}>
                  <span className={styles.rowName} title={project.name}>
                    {project.name}
                  </span>
                  <span className={styles.rowSub} style={{ color: '#EBEBF599' }}>
                    {project.port && (
                      <>
                        <span className={styles.cacheServer}>⚡︎ {l.format('Server on %@', `:${project.port}`)}</span>
                        <span>·</span>
                      </>
                    )}
                    <span className={styles.ellipsis}>
                      {project.repository ? `${l.format('%@ worktree', project.repository)} · ` : ''}
                      {kindText}
                    </span>
                    <span>·</span>
                    <span className={styles.cacheAge}>{age}</span>
                  </span>
                </span>
                <span className={styles.rowMemory}>{formatDisk(reclaimable(project.artifacts))}</span>
                <button
                  type="button"
                  className={styles.cacheChevron}
                  data-open={open}
                  aria-expanded={open}
                  aria-label={l.text(open ? 'Less' : 'Show folders')}
                  title={l.text(open ? 'Less' : 'Show folders')}
                  onClick={(e) => {
                    e.stopPropagation()
                    setExpanded((current) => (open ? current.filter((n) => n !== project.name) : [...current, project.name]))
                  }}
                >
                  <Chevron direction="down" />
                </button>
              </div>
              <div className={styles.collapsible} data-open={open}>
                <div>
                  {[...project.artifacts]
                    .sort((a, b) => b.reclaimable - a.reclaimable)
                    .map((a) => (
                      <div
                        key={a.id}
                        role="button"
                        tabIndex={open ? 0 : -1}
                        className={styles.cacheGroup}
                        onClick={() => demo.toggleCaches([a.id])}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault()
                            demo.toggleCaches([a.id])
                          }
                        }}
                      >
                        <Check state={checkState([a], demo.cacheSelection)} small />
                        <span className={`${styles.mono} ${styles.ellipsis}`}>
                          {a.count ? l.format('%@ · %d folders', a.path, a.count) : a.path}
                        </span>
                        {a.size > a.reclaimable * 2 && (
                          <span className={styles.t3}>{l.format('%@ shared', formatDisk(a.size - a.reclaimable))}</span>
                        )}
                        <span className={`${styles.mono} ${styles.t2} ${styles.cacheGroupSize}`}>{formatDisk(a.reclaimable)}</span>
                      </div>
                    ))}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {!projects.length ? (
        <div className={`${styles.popSection} ${styles.actions}`}>
          <button type="button" className={styles.primaryAction} onClick={demo.restoreCaches}>
            Bring the demo caches back
          </button>
        </div>
      ) : confirming ? (
        <div className={`${styles.popSection} ${styles.cleanFooter}`}>
          <span className={`${styles.caption} ${styles.t2}`}>
            {l.text('Deleted folders are gone for good. Your tools recreate them on the next install or build.')}
          </span>
          <div className={styles.cacheActions}>
            <button type="button" className={styles.secondaryAction} onClick={() => setConfirming(false)}>
              {l.text('Cancel')}
            </button>
            <button type="button" className={`${styles.primaryAction} ${styles.destructive}`} onClick={confirmDelete}>
              {l.format('Delete %d %@', selectedFolders, l.counted('folder', 'folders', selectedFolders))}
            </button>
          </div>
        </div>
      ) : (
        <div className={`${styles.popSection} ${styles.actions}`}>
          {selected.length ? (
            <button type="button" className={styles.secondaryAction} onClick={() => demo.setCacheSelection([])}>
              {l.text('Clear')}
            </button>
          ) : (
            <button
              type="button"
              className={styles.secondaryAction}
              disabled={!suggestion.length}
              onClick={() => demo.setCacheSelection(suggestion)}
            >
              {l.text('Select unused')}
            </button>
          )}
          <button
            type="button"
            className={`${styles.primaryAction} ${styles.destructive}`}
            disabled={!selected.length}
            onClick={() => setConfirming(true)}
          >
            <svg width="13" height="13" viewBox="0 0 14 14" aria-hidden style={{ marginInlineEnd: 7 }}>
              <path
                d="M2.5 3.8h9M5.6 3.8V2.4h2.8v1.4M3.6 3.8l.6 7.6c0 .5.4.8.9.8h3.8c.5 0 .9-.3.9-.8l.6-7.6"
                fill="none"
                stroke="#FFFFFF"
                strokeWidth="1.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
            {selected.length ? l.format('Free %@', formatDisk(selectedMb)) : l.text('Delete caches')}
          </button>
          <button type="button" className={styles.moreAction} aria-label="More">
            <span />
            <span />
            <span />
          </button>
        </div>
      )}
    </>
  )
}

// The deletion queue under the disk bar (CleanupCard in BuildCachesView.swift).
function CleanupCard({ demo, l, freedMb }: { demo: Demo; l: Localizer; freedMb: number }) {
  const [open, setOpen] = useState(false)
  const jobs = demo.cacheJobs
  const current = jobs.find((j) => j.state === 'deleting')
  const done = jobs.filter((j) => j.state === 'done').length
  const queued = jobs.filter((j) => j.state === 'queued').length
  const finished = done === jobs.length
  const count = finished
    ? l.format('%d %@', jobs.length, l.counted('folder', 'folders', jobs.length))
    : l.format('%d of %d', Math.min(done + 1, jobs.length), jobs.length)
  const label = (id: string) => {
    const project = CACHE_PROJECTS.find((p) => p.artifacts.some((a) => a.id === id))!
    const a = project.artifacts.find((a) => a.id === id)!
    return (
      <span className={styles.cleanupLabel}>
        <span className={`${styles.mono} ${styles.ellipsis}`}>{a.count ? l.format('%@ · %d folders', a.path, a.count) : a.path}</span>
        <span className={`${styles.t3} ${styles.ellipsis}`}>{project.name}</span>
      </span>
    )
  }
  return (
    <div className={styles.cleanupCard} data-open={open}>
      <button
        type="button"
        className={styles.cleanupHead}
        aria-expanded={open}
        title={l.text(open ? 'Less' : 'Show folders')}
        onClick={() => setOpen(!open)}
      >
        {current ? (
          <>
            <Spinner />
            {label(current.id)}
          </>
        ) : (
          <>
            <JobIcon state="done" />
            <span className={styles.cleanupLabel}>{l.format('Freed %@', formatDisk(freedMb))}</span>
          </>
        )}
        <span className={`${styles.mono} ${styles.t3} ${styles.cleanupCount}`}>{count}</span>
        <span className={styles.cacheChevron} data-open={open}>
          <Chevron direction="down" />
        </span>
      </button>
      <div className={styles.collapsible} data-open={open}>
        <div>
          <div className={styles.cleanupJobs}>
            {jobs.map((job) => (
              <div key={job.id} className={styles.cleanupJob} data-state={job.state}>
                {job.state === 'deleting' ? <Spinner /> : <JobIcon state={job.state} />}
                {label(job.id)}
                <span className={`${styles.mono} ${styles.t2}`}>{formatDisk(cacheSize(job.id))}</span>
              </div>
            ))}
          </div>
          {queued > 0 && (
            <button
              type="button"
              className={styles.cleanupCancel}
              tabIndex={open ? 0 : -1}
              title={l.text("Puts the folders that haven't started back in the list.")}
              onClick={demo.cancelQueuedCaches}
            >
              {l.format('Cancel %d queued', queued)}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// How much of the queue is done, by size (ProgressRing).
function ProgressRing({ fraction }: { fraction: number }) {
  const length = 2 * Math.PI * 5
  return (
    <svg className={styles.progressRing} width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <circle cx="6" cy="6" r="5" fill="none" stroke="#f5f5f726" strokeWidth="2" />
      <circle
        cx="6"
        cy="6"
        r="5"
        fill="none"
        stroke="#f5f5f7cc"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={length}
        strokeDashoffset={length * (1 - Math.max(fraction, 0.03))}
        transform="rotate(-90 6 6)"
      />
    </svg>
  )
}

// macOS's small indeterminate spinner.
function Spinner() {
  return (
    <svg className={styles.spinner} width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      {Array.from({ length: 8 }, (_, i) => (
        <path
          key={i}
          d="M6 1.2v2.2"
          stroke="#ebebf5"
          strokeWidth="1.3"
          strokeLinecap="round"
          opacity={0.25 + (i / 8) * 0.6}
          transform={`rotate(${i * 45} 6 6)`}
        />
      ))}
    </svg>
  )
}

function JobIcon({ state }: { state: 'queued' | 'done' }) {
  return state === 'done' ? (
    <svg className={styles.jobIcon} width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <path d="M3 6.3l2 2 4-4.6" fill="none" stroke="#ebebf599" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ) : (
    <svg className={styles.jobIcon} width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <circle cx="6" cy="6" r="4.5" fill="none" stroke="#ebebf566" strokeWidth="1" strokeDasharray="2 2" />
    </svg>
  )
}

const REASON_ICONS = {
  deleted: (
    <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden>
      <path
        d="M1.5 3.5c0-.6.4-1 1-1h2.3l1 1.2h3.7c.6 0 1 .4 1 1V9c0 .6-.4 1-1 1h-7c-.6 0-1-.4-1-1V3.5Z"
        fill="none"
        stroke="rgb(235 235 245 / 60%)"
        strokeWidth="1.1"
      />
      <path d="M4.5 6.2h3" fill="none" stroke="rgb(235 235 245 / 60%)" strokeWidth="1.1" strokeLinecap="round" />
    </svg>
  ),
  idle: (
    <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden>
      <circle cx="6" cy="6" r="4.5" fill="none" stroke="rgb(235 235 245 / 60%)" strokeWidth="1.1" />
      <path d="M6 3.6V6l1.6 1" fill="none" stroke="rgb(235 235 245 / 60%)" strokeWidth="1.1" strokeLinecap="round" />
    </svg>
  ),
  leaking: (
    <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden>
      <path
        d="M1.5 9 4.5 6l2 2 4-4.5M7.5 3.5h3v3"
        fill="none"
        stroke={AMBER}
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  ),
}
