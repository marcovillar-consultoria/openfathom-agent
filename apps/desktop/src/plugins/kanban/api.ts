/**
 * Kanban data layer. Everything goes through `ctx.rest` — the plugin's own
 * `/api/plugins/kanban/*` FastAPI router (`plugins/kanban/dashboard/plugin_api.py`),
 * reused as-is via the desktop's namespace-scoped REST door. No new backend.
 *
 * Fetching, caching, polling, dedupe, and invalidation are React Query's job
 * (the app's standard, via the SDK). This module owns the query keys, the REST
 * calls, and the selected-board atom — every call passes `?board=<slug>` so the
 * desktop's selection never flips the server-wide current-board pointer.
 */

import { atom, type PluginRestOptions, type PluginStorage } from '@hermes/plugin-sdk'

import type {
  BoardsResponse,
  KanbanBoard,
  KanbanProfile,
  KanbanTask,
  KanbanTaskDetail,
  OrchestrationSettings,
  WorkerLog
} from './types'

type Rest = <T>(path: string, opts?: PluginRestOptions) => Promise<T>

let rest: null | Rest = null

/** Selected board slug ('' = the server's current board). Persisted. */
export const $boardSlug = atom<string>('')

/** Whether the "how this board works" intro was dismissed. Persisted. */
export const $introDismissed = atom<boolean>(false)

const BOARD_SLUG_KEY = 'boardSlug'
const INTRO_KEY = 'introDismissed'

/** Bind the plugin's REST door + storage once, at register time. */
export function bindApi(r: Rest, storage: PluginStorage): void {
  rest = r
  $boardSlug.set(storage.get(BOARD_SLUG_KEY, ''))
  $boardSlug.listen(slug => storage.set(BOARD_SLUG_KEY, slug))
  $introDismissed.set(storage.get(INTRO_KEY, false))
  $introDismissed.listen(dismissed => storage.set(INTRO_KEY, dismissed))
}

function call<T>(path: string, opts?: PluginRestOptions): Promise<T> {
  return rest ? rest<T>(path, opts) : Promise.reject(new Error('kanban api not ready'))
}

/** Append the selected board (and other params) to a path. */
function withBoard(path: string, params: Record<string, string> = {}): string {
  const search = new URLSearchParams(params)
  const slug = $boardSlug.get()

  if (slug) {
    search.set('board', slug)
  }

  const qs = search.toString()

  return qs ? `${path}?${qs}` : path
}

// ── query keys (all board-scoped so switching boards is a clean cache miss) ──

export const boardKey = (slug: string, archived: boolean) => ['kanban', 'board', slug, archived] as const
export const taskKey = (slug: string, id: string) => ['kanban', 'task', slug, id] as const
export const logKey = (slug: string, id: string) => ['kanban', 'log', slug, id] as const
export const BOARDS_KEY = ['kanban', 'boards'] as const
export const PROFILES_KEY = ['kanban', 'profiles'] as const
export const ORCHESTRATION_KEY = ['kanban', 'orchestration'] as const

// ── reads ─────────────────────────────────────────────────────────────────────

export const fetchBoard = (archived: boolean) =>
  call<KanbanBoard>(withBoard('/board', archived ? { include_archived: 'true' } : {}))

export const fetchTask = (id: string) => call<KanbanTaskDetail>(withBoard(`/tasks/${id}`))

/** Worker stdout/stderr tail (last 16 KiB — plenty for the drawer). */
export const fetchLog = (id: string) => call<WorkerLog>(withBoard(`/tasks/${id}/log`, { tail: '16384' }))

export const fetchBoards = () => call<BoardsResponse>('/boards')

export const fetchProfiles = () => call<{ profiles: KanbanProfile[] }>('/profiles')

export const fetchOrchestration = () => call<OrchestrationSettings>('/orchestration')

// ── writes ────────────────────────────────────────────────────────────────────

export const patchTask = (id: string, patch: Record<string, unknown>) =>
  call(withBoard(`/tasks/${id}`), { method: 'PATCH', body: patch })

export const createTask = (body: Record<string, unknown>) =>
  call<{ task: KanbanTask | null; warning?: string }>(withBoard('/tasks'), { method: 'POST', body })

export const deleteTask = (id: string) => call(withBoard(`/tasks/${id}`), { method: 'DELETE' })

export const addComment = (id: string, body: string) =>
  call(withBoard(`/tasks/${id}/comments`), { method: 'POST', body: { author: 'desktop', body } })

export const reassignTask = (id: string, profile: string) =>
  call(withBoard(`/tasks/${id}/reassign`), { method: 'POST', body: { profile, reclaim_first: true } })

export const createBoard = (slug: string, name: string) =>
  call<{ board: { slug: string } }>('/boards', { method: 'POST', body: { slug, name } })

export const nudgeDispatcher = () =>
  call<{ spawned?: unknown[] }>(withBoard('/dispatch'), { method: 'POST', body: {} })

export const saveOrchestration = (patch: Record<string, unknown>) =>
  call<OrchestrationSettings>('/orchestration', { method: 'PUT', body: patch })

export const saveProfileDescription = (name: string, description: string) =>
  call(`/profiles/${encodeURIComponent(name)}`, { method: 'PATCH', body: { description } })

export const autoDescribeProfile = (name: string) =>
  call<{ ok: boolean; reason?: null | string; description?: null | string }>(
    `/profiles/${encodeURIComponent(name)}/describe-auto`,
    { method: 'POST', body: { overwrite: true } }
  )
