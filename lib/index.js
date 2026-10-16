/**
 * dsh-chat-panel -- host half.
 *
 * Purpose
 * -------
 * Give the browser side a way to ask the machine to arrange windows. A page
 * cannot reposition top-level browser windows itself (window.resizeTo is
 * ignored for windows the script did not open), so this half shells out to
 * lib/window.ps1, which uses Win32 to size the DSH window and place a separate
 * chat.deepseek.com window beside it.
 *
 * Trust boundary
 * --------------
 * These routes affect the local desktop, so they are fenced:
 *   - the Host header must be a loopback authority (or an explicitly listed one)
 *   - Sec-Fetch-Site: cross-site is refused
 *   - an Origin header, when present, must equal the Host
 * All checks fail closed.
 *
 * Nothing here touches credentials. The only outbound destination is
 * chat.deepseek.com, opened by Edge in its own isolated profile.
 */

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

export const name = 'dsh-chat-panel'

/** Absolute path of the helper script, resolved next to this module. */
const HERE = path.dirname(fileURLToPath(import.meta.url))
const WINDOW_SCRIPT = path.join(HERE, 'window.ps1')

/**
 * Diagnostics log. Every request and every line the helper script prints lands
 * here. This exists to make "clicking the button does nothing" diagnosable:
 * if a click leaves no trace, the request never reached the host and the fault
 * is in the client half; if it does, the script's own output says how far it got.
 */
const LOG_PATH = path.join(os.homedir(), '.dsh', 'dsh-chat-panel.log')

function logLine(message) {
  try {
    fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${message}\n`)
  } catch {
    /* diagnostics must never break a request */
  }
}

const ROUTE_OPEN = '/dsh-chat-panel/open'
const ROUTE_CLOSE = '/dsh-chat-panel/close'
const ROUTE_RESTORE = '/dsh-chat-panel/restore'
const ROUTE_STATE = '/dsh-chat-panel/state'

/**
 * State file written by the window manager. The client polls ROUTE_STATE so the
 * sidebar button can show "DeepSeek" or "关闭 chat.deepseek" for the real state
 * rather than tracking it locally -- a locally tracked flag goes stale as soon
 * as the chat is closed with its own X button or toggled with Ctrl+Alt+D.
 */
const STATE_PATH = path.join(os.homedir(), '.dsh', 'dsh-chat-panel.state')

function readState() {
  try {
    return String(fs.readFileSync(STATE_PATH, 'utf8')).trim() === 'open'
  } catch {
    return false
  }
}

/** Extra authorities allowed to drive these routes, comma separated. */
const TRUSTED = String(process.env.DSH_CHAT_PANEL_HOSTS || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean)

function isLoopback(hostname) {
  const h = String(hostname || '').toLowerCase().replace(/^\[/, '').replace(/\]$/, '')
  if (!h) return false
  if (h === 'localhost' || h.endsWith('.localhost')) return true
  if (h === '::1') return true
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h)
  if (!m) return false
  if (Number(m[1]) !== 127) return false
  return [m[2], m[3], m[4]].every((x) => Number(x) <= 255)
}

/** Returns a status code to reject with, or null to allow. */
function fence(req) {
  try {
    const headers = (req && req.headers) || {}
    let hostUrl
    try {
      hostUrl = new URL('http://' + String(headers.host || ''))
    } catch {
      return 403
    }
    const authority = hostUrl.host.toLowerCase()
    const hostname = hostUrl.hostname.toLowerCase()
    const listed = TRUSTED.some((e) => (e.includes(':') ? e === authority : e === hostname))
    if (!isLoopback(hostname) && !listed) return 403

    if (String(headers['sec-fetch-site'] || '').toLowerCase() === 'cross-site') return 403

    const origin = headers.origin
    if (typeof origin === 'string' && origin && origin !== 'null') {
      let originUrl
      try {
        originUrl = new URL(origin)
      } catch {
        return 403
      }
      if (originUrl.host.toLowerCase() !== authority) return 403
    }
    return null
  } catch {
    return 403
  }
}

/**
 * Launch the window manager without blocking the request. unref() keeps DSH from
 * waiting on it. The script's stdout and stderr are appended to the diagnostics
 * log rather than discarded, which is what makes a silent failure visible.
 */
function runWindowScript(mode) {
  const ps = process.env.SystemRoot
    ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    : 'powershell.exe'

  const args = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', WINDOW_SCRIPT,
    '-Mode', mode,
  ]

  // The script's own output goes to the diagnostics log, so its progress and any
  // PowerShell error survive instead of being discarded.
  let out = 'ignore'
  try {
    out = fs.openSync(LOG_PATH, 'a')
  } catch {
    /* fall back to discarding */
  }

  // NOT detached.
  //
  // On Windows, spawn({ detached: true }) made PowerShell exit without ever
  // running the script. spawn() still returned a pid, so the route reported
  // success and the client showed "opened" -- while nothing happened on screen
  // and the diagnostics log stayed empty. Verified directly: with detached:true
  // the script never writes its marker file; without it the script runs and its
  // output lands in the log. unref() alone is enough to keep DSH from waiting.
  const child = spawn(ps, args, {
    stdio: ['ignore', out, out],
    windowsHide: true,
  })
  child.unref()
  return child.pid
}

function json(res, status, body) {
  const text = JSON.stringify(body)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': String(Buffer.byteLength(text)),
  })
  res.end(text)
}

export function apply(ctx) {
  // Local wait: registering the routes must not gate the plugin's own apply,
  // and a composition without webServer should stay quiet rather than pending.
  ctx.inject(['webServer'], (webCtx) => {
    const server = webCtx.webServer
    if (!server || typeof server.register !== 'function') {
      ctx.logger?.warn?.('dsh-chat-panel: webServer.register unavailable; routes not mounted')
      return
    }

    const mount = (routePath, mode) =>
      webCtx.effect(
        () =>
          server.register({
            kind: 'exact',
            path: routePath,
            handler: (req, res) => {
              const where = `${req.method} ${routePath}`
              const deny = fence(req)
              if (deny !== null) {
                logLine(
                  `${where} -> rejected ${deny} ` +
                  `(host=${(req.headers && req.headers.host) || '-'} ` +
                  `origin=${(req.headers && req.headers.origin) || '-'} ` +
                  `sfs=${(req.headers && req.headers['sec-fetch-site']) || '-'})`,
                )
                json(res, deny, { ok: false, error: 'forbidden' })
                return
              }
              if (req.method !== 'POST') {
                logLine(`${where} -> 405 method-not-allowed`)
                json(res, 405, { ok: false, error: 'method-not-allowed' })
                return
              }
              try {
                const pid = runWindowScript(mode)
                logLine(`${where} -> spawned mode=${mode} pid=${pid}`)
                json(res, 200, { ok: true, mode, pid })
              } catch (error) {
                const text = String((error && error.message) || error)
                logLine(`${where} -> spawn failed: ${text}`)
                json(res, 500, { ok: false, error: text })
              }
            },
          }),
        `dsh-chat-panel: ${routePath}`,
      )

    mount(ROUTE_OPEN, 'open')
    mount(ROUTE_CLOSE, 'close')
    mount(ROUTE_RESTORE, 'restore')

    // GET only: reports whether the chat pane is currently open, so the sidebar
    // button can label itself correctly after a refresh, a Ctrl+Alt+D toggle, or
    // the chat being closed by its own X.
    webCtx.effect(
      () =>
        server.register({
          kind: 'exact',
          path: ROUTE_STATE,
          handler: (req, res) => {
            const deny = fence(req)
            if (deny !== null) {
              json(res, deny, { ok: false, error: 'forbidden' })
              return
            }
            if (req.method !== 'GET' && req.method !== 'HEAD') {
              json(res, 405, { ok: false, error: 'method-not-allowed' })
              return
            }
            json(res, 200, { ok: true, open: readState() })
          },
        }),
      `dsh-chat-panel: ${ROUTE_STATE}`,
    )
  })
}
