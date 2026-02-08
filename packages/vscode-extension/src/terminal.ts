import * as vscode from 'vscode';
import { randomUUID } from 'node:crypto';

// =============================================================================
// Types
// =============================================================================

// Unique client ID for this VSCode instance
const CLIENT_ID = randomUUID();

interface TerminalMetadata {
  /** Where to open the terminal: "editor" for Editor pane, "panel" for bottom Panel */
  location?: 'editor' | 'panel';
  /** Terminal type for identification */
  type?: 'agent' | 'dev' | 'maintenance' | 'shell';
  /** Explicitly mark as cmux-managed */
  managed?: boolean;
  /** Any other custom fields */
  [key: string]: unknown;
}

interface TerminalInfo {
  id: string;
  name: string;
  index: number;
  shell: string;
  cwd: string;
  cols: number;
  rows: number;
  created_at: number;
  alive: boolean;
  pid: number;
  /** Flexible metadata for client use */
  metadata?: TerminalMetadata;
}

interface PTYMessage {
  type: 'output' | 'exit' | 'error';
  data?: string;
  exit_code?: number | null;  // Server sends snake_case
  exitCode?: number;          // Keep for compatibility
}

interface StateSyncEvent {
  type: 'state_sync';
  terminals: TerminalInfo[];
}

interface PTYCreatedEvent {
  type: 'pty_created';
  terminal: TerminalInfo;
  creator_client_id?: string;
}

interface PTYUpdatedEvent {
  type: 'pty_updated';
  terminal: TerminalInfo;
  changes: { name?: string; index?: number };
}

interface PTYDeletedEvent {
  type: 'pty_deleted';
  pty_id: string;
}

type _PTYEvent = StateSyncEvent | PTYCreatedEvent | PTYUpdatedEvent | PTYDeletedEvent;

function getConfig() {
  const config = vscode.workspace.getConfiguration('cmux');
  return {
    serverUrl: config.get<string>('ptyServerUrl', 'http://localhost:39383'),
    defaultShell: config.get<string>('defaultShell', '/bin/zsh'),
  };
}

const RESTORE_FALLBACK_DELAY_MS = 1500;
const RECONCILE_INTERVAL_MS = 15000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isTerminalInfo(value: unknown): value is TerminalInfo {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === 'string' &&
    typeof value.name === 'string' &&
    typeof value.index === 'number' &&
    typeof value.shell === 'string' &&
    typeof value.cwd === 'string' &&
    typeof value.cols === 'number' &&
    typeof value.rows === 'number' &&
    typeof value.created_at === 'number' &&
    typeof value.alive === 'boolean' &&
    typeof value.pid === 'number'
  );
}

function extractTerminalInfos(payload: unknown): TerminalInfo[] | null {
  if (Array.isArray(payload)) {
    return payload.filter(isTerminalInfo);
  }
  if (isRecord(payload) && Array.isArray(payload.sessions)) {
    return payload.sessions.filter(isTerminalInfo);
  }
  return null;
}


// =============================================================================
// CmuxPseudoterminal - Connects to a single PTY session
// =============================================================================

class CmuxPseudoterminal implements vscode.Pseudoterminal {
  private readonly _onDidWrite = new vscode.EventEmitter<string>();
  private readonly _onDidClose = new vscode.EventEmitter<number | void>();

  private _ws: WebSocket | null = null;
  private _isDisposed = false;
  private _initialDataSent = false;
  private _outputBuffer = '';
  private _dimensions: { cols: number; rows: number } = { cols: 80, rows: 24 };
  private _previousDimensions: { cols: number; rows: number } | null = null;
  private _skipInitialResize: boolean;
  private _hasConnectedOnce = false;
  private _reconnectAttempts = 0;
  private _reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private _reconnectBaseDelayMs = 500;
  private _reconnectMaxDelayMs = 30000;
  private _showedDisconnectMessage = false;

  // Track if close was due to process exit (should delete session) vs unexpected disconnect (should reconnect)
  private _processExited = false;

  public readonly onDidWrite: vscode.Event<string> = this._onDidWrite.event;
  public readonly onDidClose: vscode.Event<number | void> = this._onDidClose.event;

  constructor(
    private readonly serverUrl: string,
    public readonly ptyId: string,
    skipInitialResize = false // For restored sessions, skip resize on connect to avoid prompt redraw
  ) {
    console.log(`[cmux] CmuxPseudoterminal constructor for PTY ${ptyId}, skipInitialResize: ${skipInitialResize}`);
    this._skipInitialResize = skipInitialResize;
    this._connectWebSocket();
  }

  private _connectWebSocket(): void {
    if (this._isDisposed) return;
    if (this._ws && (this._ws.readyState === WebSocket.OPEN || this._ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    const wsUrl = this.serverUrl.replace(/^http/, 'ws');
    const fullUrl = `${wsUrl}/sessions/${this.ptyId}/ws`;
    console.log(`[cmux] CmuxPseudoterminal connecting to: ${fullUrl}`);
    const ws = new WebSocket(fullUrl);
    this._ws = ws;

    ws.onopen = () => {
      if (this._ws !== ws) return;
      console.log(`[cmux] WebSocket connected for PTY ${this.ptyId}`);

      if (this._reconnectTimer) {
        clearTimeout(this._reconnectTimer);
        this._reconnectTimer = null;
      }
      if (this._showedDisconnectMessage) {
        this._writeStatusMessage('\r\n[cmux] Terminal connection restored.\r\n');
        this._showedDisconnectMessage = false;
      }
      const isFirstConnect = !this._hasConnectedOnce;
      this._hasConnectedOnce = true;
      this._reconnectAttempts = 0;

      // Skip initial resize only on the first connect for restored sessions
      // The proper resize will be sent when open() is called with actual dimensions
      if (!(isFirstConnect && this._skipInitialResize)) {
        this._ws?.send(JSON.stringify({
          type: 'resize',
          cols: this._dimensions.cols,
          rows: this._dimensions.rows,
        }));
      }
    };

    ws.onmessage = async (event) => {
      if (this._ws !== ws) return;
      if (this._isDisposed) return;

      try {
        // Convert to string first
        let text: string;
        if (event.data instanceof Blob) {
          text = await event.data.text();
        } else if (event.data instanceof ArrayBuffer) {
          text = new TextDecoder().decode(event.data);
        } else if (typeof event.data === 'string') {
          text = event.data;
        } else {
          console.error('[cmux] Unknown message type:', typeof event.data);
          return;
        }

        // Control messages are prefixed with \x00 to distinguish from regular PTY output
        if (text.startsWith('\x00')) {
          try {
            const jsonText = text.slice(1); // Remove the null byte prefix
            const msg: PTYMessage = JSON.parse(jsonText);
            if (msg.type === 'exit') {
              const exitCode = msg.exit_code ?? msg.exitCode ?? 0;
              console.log(`[cmux] PTY ${this.ptyId} received exit event, code: ${exitCode}`);
              // Mark that the process exited - this prevents reconnection attempts
              // and allows the session to be properly deleted
              this._processExited = true;
              this._onDidClose.fire(exitCode);
              this.dispose();
              return;
            } else if (msg.type === 'output' && msg.data) {
              text = msg.data;
            } else if (msg.type === 'error') {
              console.error('[cmux] PTY error:', msg);
              return;
            }
          } catch {
            // Malformed control message, ignore
            console.error('[cmux] Failed to parse control message');
            return;
          }
        }

        // Write output to terminal
        if (text) {
          if (!this._initialDataSent) {
            this._outputBuffer += text;
          } else {
            this._onDidWrite.fire(text);
          }
        }
      } catch (e) {
        console.error('[cmux] Failed to process PTY message:', e);
      }
    };

    ws.onerror = (error) => {
      if (this._ws !== ws) return;
      console.error('WebSocket error:', error);
      if (!this._initialDataSent) {
        this._outputBuffer += '\r\nWebSocket connection error\r\n';
      } else {
        this._onDidWrite.fire('\r\nWebSocket connection error\r\n');
      }
    };

    ws.onclose = () => {
      if (this._ws !== ws) return;
      if (this._isDisposed) return;
      // Don't reconnect if the process exited - the session should be deleted
      if (this._processExited) {
        this._onDidClose.fire();
        return;
      }
      this._scheduleReconnect();
    };
  }

  private _writeStatusMessage(message: string): void {
    if (this._isDisposed) return;
    if (!this._initialDataSent) {
      this._outputBuffer += message;
      return;
    }
    this._onDidWrite.fire(message);
  }

  private _scheduleReconnect(): void {
    if (this._isDisposed) return;
    if (this._processExited) return;
    if (this._reconnectTimer) return;

    if (!this._showedDisconnectMessage) {
      this._writeStatusMessage('\r\n[cmux] Terminal connection lost. Reconnecting...\r\n');
      this._showedDisconnectMessage = true;
    }

    const delay = Math.min(
      this._reconnectBaseDelayMs * Math.pow(2, this._reconnectAttempts),
      this._reconnectMaxDelayMs
    );
    this._reconnectAttempts += 1;
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this._connectWebSocket();
    }, delay);
  }

  open(initialDimensions: vscode.TerminalDimensions | undefined): void {
    console.log(`[cmux] PTY ${this.ptyId} open() called, buffer size: ${this._outputBuffer.length}`);

    // Flush buffered output
    if (this._outputBuffer.length > 0) {
      this._onDidWrite.fire(this._outputBuffer);
      this._outputBuffer = '';
    }
    this._initialDataSent = true;

    if (initialDimensions) {
      this._dimensions = { cols: initialDimensions.columns, rows: initialDimensions.rows };
      this._previousDimensions = { ...this._dimensions };
      if (this._ws && this._ws.readyState === WebSocket.OPEN) {
        this._ws.send(JSON.stringify({
          type: 'resize',
          cols: initialDimensions.columns,
          rows: initialDimensions.rows,
        }));
      }
    }
  }

  close(): void {
    // Do NOT delete the PTY session - it should persist on the server (like tmux)
    // The user can reconnect to it after a page refresh
    // Only close the WebSocket connection
    this.dispose();
  }

  handleInput(data: string): void {
    if (this._ws && this._ws.readyState === WebSocket.OPEN && !this._isDisposed) {
      this._ws.send(JSON.stringify({ type: 'input', data }));
    }
  }

  setDimensions(dimensions: vscode.TerminalDimensions): void {
    const newDimensions = { cols: dimensions.columns, rows: dimensions.rows };

    // Check if we're shrinking - need to clear outside content
    if (this._previousDimensions && this._initialDataSent) {
      const shrinkingCols = newDimensions.cols < this._previousDimensions.cols;
      const shrinkingRows = newDimensions.rows < this._previousDimensions.rows;

      if (shrinkingCols || shrinkingRows) {
        // Send ANSI sequence to clear screen and reset cursor
        // This prevents artifacts when terminal shrinks
        // ESC[2J = clear entire screen, ESC[H = move cursor to home
        this._onDidWrite.fire('\x1b[2J\x1b[H');
      }
    }

    this._previousDimensions = { ...this._dimensions };
    this._dimensions = newDimensions;

    if (this._ws && this._ws.readyState === WebSocket.OPEN && !this._isDisposed) {
      this._ws.send(JSON.stringify({
        type: 'resize',
        cols: dimensions.columns,
        rows: dimensions.rows,
      }));
    }
  }

  dispose(): void {
    if (this._isDisposed) return;
    this._isDisposed = true;

    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }

    if (this._ws) {
      this._ws.close();
      this._ws = null;
    }

    this._onDidWrite.dispose();
    this._onDidClose.dispose();
  }

  /**
   * Check if the terminal was closed due to process exit (vs unexpected disconnect).
   * Used by the terminal manager to decide whether to delete the PTY session.
   */
  get processExited(): boolean {
    return this._processExited;
  }
}

// =============================================================================
// PtyClient - WebSocket connection for events
// =============================================================================

class PtyClient {
  private _ws: WebSocket | null = null;
  private _eventHandlers = new Map<string, ((data: unknown) => void)[]>();
  private _connected = false;
  private _reconnectAttempts = 0;
  private _maxReconnectAttempts = 10;
  private _reconnectDelay = 1000;

  constructor(private readonly serverUrl: string) {}

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const wsUrl = this.serverUrl.replace(/^http/, 'ws');
      const fullUrl = `${wsUrl}/ws`;
      console.log('[cmux] PtyClient connecting to:', fullUrl);
      this._ws = new WebSocket(fullUrl);

      // Increased timeout to 20s for Docker containers where the PTY server
      // may take longer to start (especially during initial container boot)
      const timeout = setTimeout(() => {
        if (!this._connected) {
          console.error('[cmux] PtyClient connection timeout after 20s');
          reject(new Error('Connection timeout'));
        }
      }, 20000);

      this._ws.onopen = () => {
        clearTimeout(timeout);
        this._connected = true;
        this._reconnectAttempts = 0;
        console.log('[cmux] PtyClient connected to event WebSocket');
        this._triggerEvent('connected', {});
        resolve();
      };

      this._ws.onmessage = (event) => {
        try {
          const message = JSON.parse(event.data);
          console.log('[cmux] PtyClient received message:', message.type, message);
          this._triggerEvent(message.type, message);
        } catch (err) {
          console.error('[cmux] Failed to parse message:', err);
        }
      };

      this._ws.onclose = () => {
        this._connected = false;
        console.log('PtyClient disconnected');
        this._triggerEvent('disconnected', {});
        this._tryReconnect();
      };

      this._ws.onerror = (err) => {
        clearTimeout(timeout);
        console.error('PtyClient WebSocket error:', err);
        if (!this._connected) {
          reject(err);
        }
      };
    });
  }

  private _tryReconnect(): void {
    if (this._reconnectAttempts < this._maxReconnectAttempts) {
      this._reconnectAttempts++;
      const delay = this._reconnectDelay * Math.pow(2, this._reconnectAttempts - 1);
      console.log(`Reconnecting in ${delay}ms (attempt ${this._reconnectAttempts})`);
      setTimeout(() => this.connect().catch(() => {}), delay);
    }
  }

  on<T = unknown>(event: string, handler: (data: T) => void): { dispose: () => void } {
    if (!this._eventHandlers.has(event)) {
      this._eventHandlers.set(event, []);
    }
    this._eventHandlers.get(event)!.push(handler as (data: unknown) => void);
    return {
      dispose: () => this.off(event, handler as (data: unknown) => void)
    };
  }

  off(event: string, handler: (data: unknown) => void): void {
    const handlers = this._eventHandlers.get(event);
    if (handlers) {
      const idx = handlers.indexOf(handler);
      if (idx !== -1) handlers.splice(idx, 1);
    }
  }

  private _triggerEvent(event: string, data: unknown): void {
    const handlers = this._eventHandlers.get(event) || [];
    for (const handler of handlers) {
      try {
        handler(data);
      } catch (err) {
        console.error(`Error in event handler for ${event}:`, err);
      }
    }
  }

  requestState(): void {
    if (this._ws && this._ws.readyState === WebSocket.OPEN) {
      this._ws.send(JSON.stringify({ type: 'get_state' }));
    }
  }

  createPty(shell?: string, cwd?: string, name?: string): void {
    if (!this._ws || this._ws.readyState !== WebSocket.OPEN) {
      console.error('Cannot create PTY: not connected');
      return;
    }
    this._ws.send(JSON.stringify({
      type: 'create_pty',
      shell: shell || '/bin/zsh',
      cwd: cwd || '/root/workspace',
      name,
      client_id: CLIENT_ID,
    }));
  }

  renamePty(ptyId: string, name: string): void {
    if (!this._ws || this._ws.readyState !== WebSocket.OPEN) {
      console.error('Cannot rename PTY: not connected');
      return;
    }
    this._ws.send(JSON.stringify({
      type: 'rename_pty',
      pty_id: ptyId,
      name,
    }));
  }

  dispose(): void {
    this._eventHandlers.clear();
    if (this._ws) {
      this._ws.close();
      this._ws = null;
    }
  }
}

// =============================================================================
// CmuxTerminalManager - Manages all terminals
// =============================================================================

interface ManagedTerminal {
  terminal: vscode.Terminal;
  pty: CmuxPseudoterminal;
  info: TerminalInfo;
  // Set to true when disposing due to server event (pty_deleted/exit)
  // Prevents re-deleting on server when onDidCloseTerminal fires
  disposingFromServer?: boolean;
}

class CmuxTerminalManager {
  // Map from ptyId to managed terminal
  private _terminals = new Map<string, ManagedTerminal>();

  // Set of ptyIds we're currently creating (to prevent duplicates)
  private _pendingCreations = new Set<string>();

  // Count of pending HTTP requests for creating PTYs
  // Used to detect when pty_created events should be skipped
  private _httpPendingCount = 0;

  // Map of terminal name → {ptyId, pty} for terminals created via provideTerminalProfile
  // Used to set up tracking when VSCode creates the terminal
  private _pendingTerminalSetup = new Map<string, { id: string; pty: CmuxPseudoterminal; info: TerminalInfo; isNewCreation?: boolean }>();

  // Queue of PTYs to restore - provideTerminalProfile consumes these
  // This allows VSCode to create terminals via profile provider while reusing existing PTYs
  private _restoreQueue: TerminalInfo[] = [];

  // True while initial restore is in progress
  // Used to skip extra provideTerminalProfile calls during page load
  // Set to false after drain completes, allowing new terminal creation
  private _restoreInProgress = false;

  private _ptyClient: PtyClient;
  private _disposables: { dispose: () => void }[] = [];
  private _initialized = false;

  // Pending DELETE operations - cancelled on dispose() to prevent deletion during page refresh
  private _pendingDeletes = new Map<string, ReturnType<typeof setTimeout>>();
  private _isDeactivating = false;

  // Track initial sync state
  private _initialSyncDone = false;
  private _initialSyncPromise: Promise<void>;
  private _resolveInitialSync!: () => void;

  // Restore and reconciliation timers
  private _restoreFallbackTimer: ReturnType<typeof setTimeout> | null = null;
  private _reconcileTimer: ReturnType<typeof setInterval> | null = null;
  private _reconcileInFlight = false;

  constructor() {
    const config = getConfig();
    this._ptyClient = new PtyClient(config.serverUrl);

    // Create promise that resolves when initial state_sync is received
    this._initialSyncPromise = new Promise(resolve => {
      this._resolveInitialSync = resolve;
    });
  }

  async initialize(): Promise<void> {
    const config = getConfig();
    console.log('[cmux] CmuxTerminalManager initializing with config:', config);

    // Register handlers BEFORE connecting so we don't miss the initial state_sync
    this._registerEventHandlers();

    try {
      console.log('[cmux] Connecting to PTY server...');
      await this._ptyClient.connect();
      console.log('[cmux] Connected to PTY server');
      this._initialized = true;
      this._startReconcileLoop();
    } catch (err) {
      console.error('[cmux] Failed to connect to PTY server:', err);
      // Await the retry so initialization doesn't complete until we're connected
      // This is important for Docker containers where the PTY server may take longer to start
      console.log('[cmux] Starting connection retry sequence...');
      await this._retryConnect();
      // Note: _initialized is set by _retryConnect on success
    }
  }

  private _registerEventHandlers(): void {
    // Handle full state sync (received on connect and on request)
    this._disposables.push(
      this._ptyClient.on('state_sync', (data: StateSyncEvent) => {
        console.log('[cmux] state_sync received:', data.terminals.length, 'terminals');
        this._handleStateSync(data.terminals);
      })
    );

    // Handle new terminal created
    this._disposables.push(
      this._ptyClient.on('pty_created', (data: PTYCreatedEvent) => {
        console.log('[cmux] pty_created received:', data.terminal.id, data.terminal.name);
        this._handlePtyCreated(data.terminal, data.creator_client_id);
      })
    );

    // Handle terminal updated (rename, reorder)
    this._disposables.push(
      this._ptyClient.on('pty_updated', (data: PTYUpdatedEvent) => {
        console.log('[cmux] pty_updated received:', data.terminal.id, data.changes);
        this._handlePtyUpdated(data.terminal, data.changes);
      })
    );

    // Handle terminal deleted
    this._disposables.push(
      this._ptyClient.on('pty_deleted', (data: PTYDeletedEvent) => {
        console.log('[cmux] pty_deleted received:', data.pty_id);
        this._handlePtyDeleted(data.pty_id);
      })
    );

    // Handle reconnection
    this._disposables.push(
      this._ptyClient.on('connected', () => {
        if (this._initialized) {
          console.log('[cmux] Reconnected, requesting state sync');
          this._ptyClient.requestState();
        }
      })
    );
  }

  private async _retryConnect(): Promise<void> {
    // Increased retry count and delay for Docker containers where
    // the PTY server may take longer to become available
    const maxRetries = 20;
    const retryDelayMs = 1500;

    for (let i = 0; i < maxRetries; i++) {
      console.log(`[cmux] Retry ${i + 1}/${maxRetries} connecting to PTY server...`);
      await new Promise(r => setTimeout(r, retryDelayMs));
      try {
        await this._ptyClient.connect();
        // Handlers already registered in initialize(), just mark as initialized
        this._initialized = true;
        this._startReconcileLoop();
        console.log(`[cmux] Successfully connected to PTY server on retry ${i + 1}`);
        return;
      } catch (err) {
        console.log(`[cmux] Retry ${i + 1}/${maxRetries} failed:`, err instanceof Error ? err.message : err);
      }
    }
    // After all retries exhausted, throw an error so callers know PTY is unavailable
    // The extension will fall back to tmux in this case
    const errMsg = `Failed to connect to PTY server after ${maxRetries} retries`;
    console.error(`[cmux] ${errMsg}`);
    throw new Error(errMsg);
  }

  private _scheduleRestoreFallback(reason: string): void {
    if (this._restoreFallbackTimer) return;
    this._restoreFallbackTimer = setTimeout(() => {
      this._restoreFallbackTimer = null;
      if (!this._restoreInProgress || this._restoreQueue.length === 0) {
        return;
      }
      console.log(
        `[cmux] Restore fallback (${reason}) draining ${this._restoreQueue.length} queued terminal(s)`
      );
      this.drainRestoreQueue();
    }, RESTORE_FALLBACK_DELAY_MS);
  }

  private _startReconcileLoop(): void {
    if (this._reconcileTimer) return;
    this._reconcileTimer = setInterval(() => {
      void this._reconcileFromServer("interval");
    }, RECONCILE_INTERVAL_MS);
  }

  private _stopReconcileLoop(): void {
    if (!this._reconcileTimer) return;
    clearInterval(this._reconcileTimer);
    this._reconcileTimer = null;
  }

  private async _reconcileFromServer(reason: string): Promise<void> {
    if (this._reconcileInFlight) return;
    this._reconcileInFlight = true;
    try {
      const config = getConfig();
      const response = await fetch(`${config.serverUrl}/sessions`, {
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) {
        console.warn(
          `[cmux] Reconcile (${reason}) failed: ${response.status} ${response.statusText}`
        );
        return;
      }
      const payload: unknown = await response.json();
      const sessions = extractTerminalInfos(payload);
      if (!sessions) {
        console.warn(`[cmux] Reconcile (${reason}) received no sessions`);
        return;
      }
      this._handleStateSync(sessions);
      if (this._restoreQueue.length > 0) {
        this._scheduleRestoreFallback('reconcile');
      }
    } catch (err) {
      console.error(`[cmux] Reconcile (${reason}) error:`, err);
    } finally {
      this._reconcileInFlight = false;
    }
  }

  private async _maybePinEditorTerminal(
    terminal: vscode.Terminal,
    shouldPin: boolean,
    preserveFocus: boolean
  ): Promise<void> {
    if (!shouldPin) return;

    const previousTerminal = vscode.window.activeTerminal;
    const previousEditor = vscode.window.activeTextEditor;

    try {
      terminal.show(false);
      await vscode.commands.executeCommand('workbench.action.keepEditor');
    } catch (err) {
      console.error('[cmux] Failed to pin terminal editor:', err);
    }

    if (!preserveFocus) {
      return;
    }

    try {
      if (previousTerminal && previousTerminal !== terminal) {
        previousTerminal.show(false);
        return;
      }
      if (previousEditor) {
        await vscode.window.showTextDocument(previousEditor.document, {
          viewColumn: previousEditor.viewColumn,
          preserveFocus: true,
          preview: false,
        });
      }
    } catch (err) {
      console.error('[cmux] Failed to restore focus after pinning:', err);
    }
  }

  private _handleStateSync(terminals: TerminalInfo[]): void {
    // Sort by index to ensure correct order
    const sorted = [...terminals].sort((a, b) => a.index - b.index);

    // Track which terminals we've seen
    const seenIds = new Set<string>();

    for (const info of sorted) {
      seenIds.add(info.id);

      // Skip if we already have this terminal
      if (this._terminals.has(info.id) || this._pendingCreations.has(info.id)) {
        // Update info if terminal exists
        const managed = this._terminals.get(info.id);
        if (managed) {
          managed.info = info;
        }
        continue;
      }

      // On initial sync, queue terminals for provideTerminalProfile to consume
      // This lets VSCode create terminals via profile provider while reusing existing PTYs
      if (!this._initialSyncDone) {
        console.log(`[cmux] Queueing PTY ${info.id} for restore`);
        this._restoreQueue.push(info);
        this._pendingCreations.add(info.id);
        this._restoreInProgress = true; // Mark restore in progress
      } else {
        // After initial sync, create terminals directly (for reconnection scenarios)
        this._createTerminalForPty(info, false, true); // Is restore/reconnect
      }
    }

    // Remove terminals that no longer exist on server
    for (const [ptyId, managed] of this._terminals) {
      if (!seenIds.has(ptyId)) {
        console.log(`[cmux] Removing stale terminal ${ptyId}`);
        managed.terminal.dispose();
        this._terminals.delete(ptyId);
      }
    }

    // Mark initial sync as complete
    if (!this._initialSyncDone) {
      this._initialSyncDone = true;
      this._resolveInitialSync();
      console.log(`[cmux] Initial state sync complete, ${this._restoreQueue.length} terminals queued`);
    }

    if (this._restoreInProgress && this._restoreQueue.length > 0) {
      this._scheduleRestoreFallback('state-sync');
    }
  }

  private _handlePtyCreated(info: TerminalInfo, creatorClientId?: string): void {
    // Skip if we already have this terminal or are creating it
    if (this._terminals.has(info.id) || this._pendingCreations.has(info.id)) {
      console.log(`[cmux] Terminal for PTY ${info.id} already exists or pending, skipping`);
      // Update info if terminal exists
      const managed = this._terminals.get(info.id);
      if (managed) {
        managed.info = info;
      }
      return;
    }

    // Skip if this is our own HTTP-created PTY (provideTerminalProfile will handle it)
    // This handles the race condition where pty_created arrives before HTTP response
    if (creatorClientId === CLIENT_ID && this._httpPendingCount > 0) {
      console.log(`[cmux] Skipping pty_created for HTTP-created PTY ${info.id} (pending HTTP: ${this._httpPendingCount})`);
      // Mark as pending so any duplicate events are also skipped
      this._pendingCreations.add(info.id);
      return;
    }

    // Create terminal and focus it
    this._createTerminalForPty(info, true);
  }

  private async _handlePtyUpdated(info: TerminalInfo, changes: { name?: string; index?: number }): Promise<void> {
    const managed = this._terminals.get(info.id);
    if (!managed) return;

    // Update stored info
    managed.info = info;

    // Try to rename using VSCode's internal command
    if (changes.name) {
      console.log(`[cmux] Terminal ${info.id} renamed to "${info.name}", attempting VSCode rename`);

      // The rename command works on the active terminal, so we need to:
      // 1. Remember current active terminal
      // 2. Make our terminal active
      // 3. Run rename command
      // 4. Restore previous active terminal
      const previousActive = vscode.window.activeTerminal;
      const isOurTerminalActive = previousActive === managed.terminal;

      try {
        // Make our terminal active (but don't steal focus from editor)
        if (!isOurTerminalActive) {
          managed.terminal.show(false); // preserveFocus = false to make it active
          // Small delay to ensure terminal is active
          await new Promise(r => setTimeout(r, 50));
        }

        // Execute rename command
        await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name: info.name });
        console.log(`[cmux] VSCode rename command executed for "${info.name}"`);

        // Restore previous active terminal if different
        if (!isOurTerminalActive && previousActive) {
          previousActive.show(false);
        }
      } catch (err) {
        console.log(`[cmux] VSCode rename command failed:`, err);
      }
    }

    // VSCode doesn't allow reordering tabs programmatically
    if (changes.index !== undefined) {
      console.log(`[cmux] Terminal ${info.id} reordered to index ${info.index} (VSCode tab unchanged)`);
    }
  }

  private _handlePtyDeleted(ptyId: string): void {
    const managed = this._terminals.get(ptyId);
    if (managed) {
      console.log(`[cmux] Disposing terminal for deleted PTY ${ptyId}`);
      // Mark as disposing from server to prevent re-deleting in onDidCloseTerminal
      managed.disposingFromServer = true;
      managed.terminal.dispose();
    }
    this._terminals.delete(ptyId);
    this._pendingCreations.delete(ptyId);
  }

  private _createTerminalForPty(info: TerminalInfo, shouldFocus: boolean, isRestore = false): void {
    const config = getConfig();

    // Use metadata.location to determine where to open the terminal
    // "editor" -> Editor pane, anything else (including undefined) -> Panel
    const shouldOpenInEditor = info.metadata?.location === 'editor';

    console.log(`[cmux] Creating terminal for PTY ${info.id} (${info.name}), focus: ${shouldFocus}, restore: ${isRestore}, editor: ${shouldOpenInEditor}, metadata: ${JSON.stringify(info.metadata)}`);

    // Skip initial resize for restored sessions to avoid shell prompt redraw
    const pty = new CmuxPseudoterminal(config.serverUrl, info.id, isRestore);

    const terminal = vscode.window.createTerminal({
      name: info.name,
      pty,
      location: shouldOpenInEditor ? vscode.TerminalLocation.Editor : vscode.TerminalLocation.Panel,
    });

    const managed: ManagedTerminal = { terminal, pty, info };
    this._terminals.set(info.id, managed);

    // Show terminal with appropriate focus
    terminal.show(!shouldFocus); // preserveFocus = true means don't steal focus
    void this._maybePinEditorTerminal(terminal, shouldOpenInEditor, !shouldFocus);

    // Listen for terminal close
    const closeListener = vscode.window.onDidCloseTerminal((closedTerminal) => {
      if (closedTerminal === terminal) {
        console.log(`[cmux] Terminal for PTY ${info.id} closed`);
        this._terminals.delete(info.id);
        closeListener.dispose();
        pty.dispose();

        // Skip delete if server already deleted this PTY
        if (managed.disposingFromServer) {
          console.log(`[cmux] PTY ${info.id} was deleted by server, skipping DELETE`);
          return;
        }

        // Only delete PTY sessions when the process actually exited.
        // If the terminal closed due to unexpected WebSocket disconnect (e.g., Docker
        // networking blip), the PTY session is likely still alive on the server.
        // This is critical for local Docker containers where network issues are common.
        if (!pty.processExited) {
          console.log(`[cmux] PTY ${info.id} closed but process did not exit - preserving session on server`);
          return;
        }

        // Schedule DELETE with short delay - cancelled on dispose() during page refresh
        // This allows user-initiated closes to delete, while preserving PTYs on refresh
        const deleteTimeout = setTimeout(async () => {
          this._pendingDeletes.delete(info.id);
          if (this._isDeactivating) {
            console.log(`[cmux] Deactivating, skipping DELETE for PTY ${info.id}`);
            return;
          }
          try {
            console.log(`[cmux] Deleting PTY ${info.id} on server (process exited)`);
            await fetch(`${config.serverUrl}/sessions/${info.id}`, { method: 'DELETE' });
          } catch (err) {
            console.error(`[cmux] Failed to delete PTY ${info.id}:`, err);
          }
        }, 50);
        this._pendingDeletes.set(info.id, deleteTimeout);
      }
    });
    this._disposables.push(closeListener);
  }

  /**
   * Create a PTY via HTTP and return a Pseudoterminal for it.
   * Used by TerminalProfileProvider for synchronous terminal creation.
   */
  async createPtyAndGetTerminal(): Promise<{ pty: vscode.Pseudoterminal; name: string; id: string } | null> {
    const config = getConfig();
    const cwd = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || '/home/vscode';

    // Track that we're waiting for HTTP response
    // This prevents pty_created handler from creating duplicate terminals
    this._httpPendingCount++;

    try {
      // Create PTY via HTTP POST with our client ID
      const response = await fetch(`${config.serverUrl}/sessions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          shell: config.defaultShell,
          cwd: cwd,
          client_id: CLIENT_ID,
        }),
      });

      if (!response.ok) {
        console.error('[cmux] Failed to create PTY:', response.statusText);
        return null;
      }

      const data = await response.json() as TerminalInfo;
      console.log('[cmux] Created PTY via HTTP:', data.id, data.name);

      // Mark as pending to prevent duplicate from pty_created event
      this._pendingCreations.add(data.id);

      // Create pseudoterminal for this PTY
      const pty = new CmuxPseudoterminal(config.serverUrl, data.id);

      // Store for tracking when terminal opens
      // Mark as new creation (not restore) so handleTerminalOpened focuses it
      this._pendingTerminalSetup.set(data.name, { id: data.id, pty, info: data, isNewCreation: true });

      return { pty, name: data.name, id: data.id };
    } catch (err) {
      console.error('[cmux] Error creating PTY:', err);
      return null;
    } finally {
      this._httpPendingCount--;
    }
  }

  createTerminal(): void {
    const config = getConfig();
    const cwd = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || '/home/vscode';
    this._ptyClient.createPty(config.defaultShell, cwd);
  }

  renamePty(ptyId: string, name: string): void {
    this._ptyClient.renamePty(ptyId, name);
  }

  reconcileNow(reason: string): void {
    void this._reconcileFromServer(reason);
  }

  getTerminals(): ManagedTerminal[] {
    return Array.from(this._terminals.values())
      .sort((a, b) => a.info.index - b.info.index);
  }

  /**
   * Wait for the initial state_sync to complete.
   * Used by profile provider to avoid creating terminals during initial load.
   */
  async waitForInitialSync(): Promise<void> {
    return this._initialSyncPromise;
  }

  /**
   * Check if we have any terminals.
   */
  hasTerminals(): boolean {
    return this._terminals.size > 0;
  }

  /**
   * Check if there are queued PTYs waiting to be restored.
   */
  hasQueuedTerminals(): boolean {
    return this._restoreQueue.length > 0;
  }

  /**
   * Check if a terminal with the given name is queued for restore.
   */
  hasQueuedTerminal(name: string): boolean {
    return this._restoreQueue.some(t => t.name === name);
  }

  /**
   * Get a queued PTY to restore, if any.
   * Used by provideTerminalProfile to reuse existing PTYs on startup.
   */
  popRestoreQueue(): TerminalInfo | undefined {
    return this._restoreQueue.shift();
  }

  /**
   * Create terminals for all queued PTYs except the last one.
   * This maintains correct tab order when the last terminal is returned via profile provider.
   */
  drainAllButLast(): void {
    if (this._restoreQueue.length <= 1) {
      return; // Nothing to drain, or only one item (will be handled by popRestoreQueue)
    }

    console.log(`[cmux] Creating ${this._restoreQueue.length - 1} terminals (keeping last for profile)`);
    while (this._restoreQueue.length > 1) {
      const info = this._restoreQueue.shift()!;
      if (this._terminals.has(info.id)) {
        console.log(`[cmux] Terminal ${info.id} already exists, skipping`);
        continue;
      }
      this._createTerminalForPty(info, false, true); // Don't focus, is restore
    }
    // Note: _restoreInProgress will be set to false after the last terminal is created
    // via popRestoreQueue -> trackPendingTerminal -> handleTerminalOpened
  }

  /**
   * Mark restore as complete. Called after last terminal is handled.
   */
  markRestoreComplete(): void {
    console.log('[cmux] Restore complete');
    this._restoreInProgress = false;
  }

  /**
   * Track a terminal created via provideTerminalProfile.
   * Stores the pty so we can set up proper tracking when terminal opens.
   */
  trackPendingTerminal(info: TerminalInfo, pty: CmuxPseudoterminal): void {
    this._pendingTerminalSetup.set(info.name, { id: info.id, pty, info });
  }

  /**
   * Create terminals for any remaining PTYs in the restore queue.
   * Called after provideTerminalProfile has had a chance to consume from queue.
   * Handles edge cases:
   * - Terminal panel was closed (VSCode doesn't call provideTerminalProfile)
   * - Multiple PTYs but VSCode only calls provideTerminalProfile once
   */
  drainRestoreQueue(): void {
    if (this._restoreQueue.length === 0) {
      console.log('[cmux] Restore queue empty, restore complete');
      this._restoreInProgress = false; // Restore complete, allow new terminal creation
      return;
    }

    console.log(`[cmux] Draining restore queue: ${this._restoreQueue.length} terminals`);
    while (this._restoreQueue.length > 0) {
      const info = this._restoreQueue.shift()!;
      // Check if terminal was already created (by provideTerminalProfile or pty_created event)
      if (this._terminals.has(info.id)) {
        console.log(`[cmux] Terminal ${info.id} already exists, skipping`);
        continue;
      }
      this._createTerminalForPty(info, false, true); // Don't focus, is restore
    }
    this._restoreInProgress = false; // Restore complete, allow new terminal creation
  }

  /**
   * Check if restore is currently in progress.
   */
  isRestoreInProgress(): boolean {
    return this._restoreInProgress;
  }

  /**
   * Handle terminal open event for terminals created via provideTerminalProfile.
   * Sets up tracking and close listener using the already-created pty.
   */
  handleTerminalOpened(terminal: vscode.Terminal): void {
    const pending = this._pendingTerminalSetup.get(terminal.name);
    if (!pending) return;

    console.log(`[cmux] Setting up tracking for terminal ${terminal.name} (${pending.id})`);
    this._pendingTerminalSetup.delete(terminal.name);
    this._pendingCreations.delete(pending.id);

    // If this was the last restore and queue is empty, mark restore complete
    if (this._restoreInProgress && this._restoreQueue.length === 0) {
      this.markRestoreComplete();
    }

    // Skip if already tracked (shouldn't happen, but be safe)
    if (this._terminals.has(pending.id)) {
      console.log(`[cmux] Terminal ${pending.id} already tracked, skipping`);
      return;
    }

    const config = getConfig();

    // Create managed terminal entry using the existing pty (don't create a new one!)
    const managed: ManagedTerminal = {
      terminal,
      pty: pending.pty,
      info: pending.info,
    };
    this._terminals.set(pending.id, managed);

    // Focus new terminals or terminals with editor location
    // - New creations (user clicked +) should always be focused
    // - Restored editor terminals should be focused
    if (pending.isNewCreation || pending.info.metadata?.location === 'editor') {
      terminal.show(false); // false = take focus
    }
    const shouldPin = pending.info.metadata?.location === 'editor';
    void this._maybePinEditorTerminal(terminal, shouldPin, !pending.isNewCreation);

    // Set up close listener
    const closeListener = vscode.window.onDidCloseTerminal((closedTerminal) => {
      if (closedTerminal === terminal) {
        console.log(`[cmux] Terminal ${pending.id} closed`);
        this._terminals.delete(pending.id);
        closeListener.dispose();
        pending.pty.dispose();

        // Skip delete if server already deleted this PTY
        if (managed.disposingFromServer) {
          console.log(`[cmux] PTY ${pending.id} was deleted by server, skipping DELETE`);
          return;
        }

        // Only delete PTY sessions when the process actually exited.
        // If the terminal closed due to unexpected WebSocket disconnect (e.g., Docker
        // networking blip), the PTY session is likely still alive on the server.
        // This is critical for local Docker containers where network issues are common.
        if (!pending.pty.processExited) {
          console.log(`[cmux] PTY ${pending.id} closed but process did not exit - preserving session on server`);
          return;
        }

        // Schedule DELETE with short delay - cancelled on dispose() during page refresh
        const deleteTimeout = setTimeout(async () => {
          this._pendingDeletes.delete(pending.id);
          if (this._isDeactivating) {
            console.log(`[cmux] Deactivating, skipping DELETE for PTY ${pending.id}`);
            return;
          }
          try {
            console.log(`[cmux] Deleting PTY ${pending.id} on server (process exited)`);
            await fetch(`${config.serverUrl}/sessions/${pending.id}`, { method: 'DELETE' });
          } catch (err) {
            console.error(`[cmux] Failed to delete PTY ${pending.id}:`, err);
          }
        }, 50);
        this._pendingDeletes.set(pending.id, deleteTimeout);
      }
    });
    this._disposables.push(closeListener);
  }

  dispose(): void {
    // Mark as deactivating first - this prevents pending deletes from executing
    this._isDeactivating = true;

    // Cancel all pending DELETE operations to preserve PTYs during page refresh
    for (const [ptyId, timeout] of this._pendingDeletes) {
      console.log(`[cmux] Cancelling pending DELETE for PTY ${ptyId}`);
      clearTimeout(timeout);
    }
    this._pendingDeletes.clear();

    if (this._restoreFallbackTimer) {
      clearTimeout(this._restoreFallbackTimer);
      this._restoreFallbackTimer = null;
    }
    this._stopReconcileLoop();

    for (const d of this._disposables) {
      d.dispose();
    }
    this._ptyClient.dispose();
  }
}

// =============================================================================
// Terminal Profile Provider
// =============================================================================

let terminalManager: CmuxTerminalManager;
let initializationPromise: Promise<void> | null = null;

class CmuxTerminalProfileProvider implements vscode.TerminalProfileProvider {
  async provideTerminalProfile(
    _token: vscode.CancellationToken
  ): Promise<vscode.TerminalProfile | undefined> {
    console.log('[cmux] provideTerminalProfile called');

    // Wait for initialization - this ensures state_sync has populated the queue
    if (initializationPromise) {
      console.log('[cmux] provideTerminalProfile: waiting for initialization...');
      try {
        await initializationPromise;
      } catch (err) {
        console.error('[cmux] provideTerminalProfile: initialization failed:', err);
        // Continue anyway - we'll try to create a terminal
      }
    }

    const config = getConfig();

    // Check if there are queued PTYs to restore from state_sync
    // To maintain correct tab order, we create all terminals EXCEPT the last one
    // via createTerminal (synchronously), then return the last one as a profile.
    // This ensures order: T1, T2, ..., Tn-1 created first, Tn returned as profile.
    if (terminalManager.hasQueuedTerminals()) {
      // Create all but last terminal directly (maintains order)
      terminalManager.drainAllButLast();

      // Pop the last terminal and return it as a profile
      const lastPty = terminalManager.popRestoreQueue();
      if (lastPty) {
        console.log(`[cmux] provideTerminalProfile: restoring last queued PTY ${lastPty.id} (${lastPty.name})`);
        // Skip initial resize to avoid shell prompt redraw on reconnect
        const pty = new CmuxPseudoterminal(config.serverUrl, lastPty.id, true);

        // Track this terminal with its pty
        terminalManager.trackPendingTerminal(lastPty, pty);

        // Use metadata.location to determine where to open the terminal
        const shouldOpenInEditor = lastPty.metadata?.location === 'editor';
        return new vscode.TerminalProfile({
          name: lastPty.name,
          pty,
          ...(shouldOpenInEditor ? { location: vscode.TerminalLocation.Editor } : {}),
        });
      }
    }

    // Queue is empty - check if restore is still in progress
    if (terminalManager.isRestoreInProgress() && terminalManager.hasTerminals()) {
      // Restore in progress but queue is empty - terminals were consumed by earlier calls
      // VSCode is asking for an extra one during restore, skip it
      console.log('[cmux] provideTerminalProfile: restore in progress, focusing existing');
      const terminals = terminalManager.getTerminals();
      if (terminals.length > 0) {
        terminals[0].terminal.show();
      }
      // Mark restore complete
      terminalManager.drainRestoreQueue();
      return undefined;
    }

    // Fresh start with no existing PTYs - create a new terminal
    console.log('[cmux] provideTerminalProfile: creating new PTY');
    const result = await terminalManager.createPtyAndGetTerminal();
    if (!result) {
      console.error('[cmux] Failed to create PTY for profile');
      return undefined;
    }

    // Use Panel location (normal terminal behavior)
    return new vscode.TerminalProfile({
      name: result.name,
      pty: result.pty,
    });
  }
}

// =============================================================================
// Terminal Module Activation
// =============================================================================

export function activateTerminal(context: vscode.ExtensionContext) {
  console.log('[cmux-terminal] Terminal module activating...');
  console.log('[cmux-terminal] Client ID:', CLIENT_ID);
  console.log('[cmux] Config:', JSON.stringify(getConfig()));

  terminalManager = new CmuxTerminalManager();

  // Register terminal profile provider immediately (synchronously)
  // The provider will wait for initialization internally if needed
  context.subscriptions.push(
    vscode.window.registerTerminalProfileProvider('cmux.terminal', new CmuxTerminalProfileProvider())
  );

  // Store the initialization promise so the profile provider can wait for it
  // Note: We don't auto-create terminals - VSCode will call provideTerminalProfile
  // when it needs a terminal (based on configurationDefaults setting cmux as default)
  // IMPORTANT: Don't set initializationPromise = null inside the callback!
  // That creates a race where provideTerminalProfile sees null before sync completes.
  initializationPromise = terminalManager.initialize().then(async () => {
    console.log('[cmux] Initialization complete');
    await terminalManager.waitForInitialSync();
    console.log('[cmux] Initial sync complete, queue ready');
  }).catch((err) => {
    console.error('[cmux] Initialization failed:', err);
    throw err;
  });

  // Handle cmux-managed terminals when they open
  context.subscriptions.push(
    vscode.window.onDidOpenTerminal((terminal) => {
      // Try to handle this terminal - handleTerminalOpened checks _pendingTerminalSetup
      // and returns early if not a cmux-managed terminal. This works for renamed terminals too.
      terminalManager.handleTerminalOpened(terminal);
    })
  );

  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) {
        terminalManager.reconcileNow("window-focus");
      }
    })
  );

  // Register commands
  context.subscriptions.push(
    vscode.commands.registerCommand('cmux.newTerminal', () => {
      terminalManager.createTerminal();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('cmux.listSessions', async () => {
      const terminals = terminalManager.getTerminals();
      if (terminals.length === 0) {
        vscode.window.showInformationMessage('No active PTY sessions');
        return;
      }

      const items = terminals.map(t => ({
        label: t.info.name,
        description: `Shell: ${t.info.shell}`,
        detail: `CWD: ${t.info.cwd} | Index: ${t.info.index}`,
        terminal: t,
      }));

      const selected = await vscode.window.showQuickPick(items, {
        placeHolder: 'Select a session',
      });

      if (selected) {
        selected.terminal.terminal.show();
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('cmux.renameTerminal', async () => {
      const terminals = terminalManager.getTerminals();
      if (terminals.length === 0) {
        vscode.window.showInformationMessage('No active PTY sessions');
        return;
      }

      const items = terminals.map(t => ({
        label: t.info.name,
        description: `PTY ID: ${t.info.id.slice(0, 8)}`,
        terminal: t,
      }));

      const selected = await vscode.window.showQuickPick(items, {
        placeHolder: 'Select terminal to rename',
      });

      if (selected) {
        const newName = await vscode.window.showInputBox({
          prompt: 'Enter new name',
          value: selected.terminal.info.name,
        });

        if (newName && newName !== selected.terminal.info.name) {
          terminalManager.renamePty(selected.terminal.info.id, newName);
          vscode.window.showInformationMessage(
            `Renamed to "${newName}" (note: VSCode tab name cannot be updated after creation)`
          );
        }
      }
    })
  );

  context.subscriptions.push({
    dispose: () => terminalManager.dispose()
  });

  console.log('[cmux-terminal] Terminal module activated');
}

export function deactivateTerminal() {
  console.log('[cmux-terminal] Terminal module deactivating...');
  // PTYs persist on the server (like tmux) - no cleanup needed
  console.log('[cmux-terminal] Terminal module deactivated');
}

/**
 * Check if cmux-pty is managing a terminal with the given name.
 * Used by extension.ts to avoid creating duplicate tmux terminals.
 * Checks both active terminals and terminals queued for restore.
 */
export function hasCmuxPtyTerminal(name: string): boolean {
  if (!terminalManager) return false;
  // Check active terminals
  const terminals = terminalManager.getTerminals();
  if (terminals.some(t => t.info.name === name)) {
    return true;
  }
  // Also check queued terminals (pending restore)
  return terminalManager.hasQueuedTerminal(name);
}

/**
 * Wait for cmux-pty to sync and check if it has a terminal with the given name.
 * Returns true if cmux-pty has the terminal, false if not found after waiting.
 */
export async function waitForCmuxPtyTerminal(name: string, maxWaitMs: number = 10000): Promise<boolean> {
  if (!terminalManager) return false;

  // Wait for initial sync to complete (with timeout to avoid hanging if PTY server is down)
  const syncTimeout = 5000; // 5 seconds
  try {
    await Promise.race([
      terminalManager.waitForInitialSync(),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('Initial sync timeout')), syncTimeout)
      )
    ]);
  } catch {
    // Timeout or connection failure - fall back to tmux
    return false;
  }

  // Check if terminal exists
  if (hasCmuxPtyTerminal(name)) {
    return true;
  }

  // Wait a bit more in case state_sync arrives later
  const startTime = Date.now();
  while (Date.now() - startTime < maxWaitMs) {
    await new Promise(resolve => setTimeout(resolve, 500));
    if (hasCmuxPtyTerminal(name)) {
      return true;
    }
  }

  return false;
}

/**
 * Check if cmux-pty has ANY terminals (not just a specific name).
 * This is useful for detecting if cmux-pty is being used at all.
 */
export function hasAnyCmuxPtyTerminals(): boolean {
  if (!terminalManager) return false;
  return terminalManager.hasTerminals() || terminalManager.hasQueuedTerminals();
}

/**
 * Wait for cmux-pty to have ANY terminals.
 * Returns true if cmux-pty has any terminals, false if not found after waiting.
 * This is more reliable than waiting for a specific terminal name since
 * maintenance/dev terminals may be created before the agent's "cmux" terminal.
 */
export async function waitForAnyCmuxPtyTerminals(maxWaitMs: number = 15000): Promise<boolean> {
  if (!terminalManager) {
    console.log('[cmux] waitForAnyCmuxPtyTerminals: terminal manager not initialized');
    return false;
  }

  // Wait for initial sync to complete (with longer timeout)
  // Increased to 15 seconds for Docker containers where PTY server may take longer to start
  const syncTimeout = 15000;
  console.log(`[cmux] waitForAnyCmuxPtyTerminals: waiting for initial sync (timeout: ${syncTimeout}ms)...`);
  try {
    await Promise.race([
      terminalManager.waitForInitialSync(),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('Initial sync timeout')), syncTimeout)
      )
    ]);
    console.log('[cmux] waitForAnyCmuxPtyTerminals: initial sync complete');
  } catch (err) {
    // Timeout or connection failure - try an HTTP reconcile before falling back
    console.log('[cmux] waitForAnyCmuxPtyTerminals: initial sync failed/timed out:', err instanceof Error ? err.message : err);
    terminalManager.reconcileNow('initial-sync-timeout');
    const startFallback = Date.now();
    while (Date.now() - startFallback < maxWaitMs) {
      await new Promise(resolve => setTimeout(resolve, 500));
      if (hasAnyCmuxPtyTerminals()) {
        console.log('[cmux] waitForAnyCmuxPtyTerminals: found terminals after reconcile');
        return true;
      }
    }
    return false;
  }

  // Check if ANY terminals exist
  if (hasAnyCmuxPtyTerminals()) {
    console.log('[cmux] waitForAnyCmuxPtyTerminals: found terminals after initial sync');
    return true;
  }

  // Wait longer for terminals to be created (orchestrator may still be running)
  console.log('[cmux] waitForAnyCmuxPtyTerminals: waiting for terminals...');
  const startTime = Date.now();
  while (Date.now() - startTime < maxWaitMs) {
    await new Promise(resolve => setTimeout(resolve, 500));
    if (hasAnyCmuxPtyTerminals()) {
      console.log(`[cmux] waitForAnyCmuxPtyTerminals: found terminals after ${Date.now() - startTime}ms`);
      return true;
    }
  }

  console.log('[cmux] waitForAnyCmuxPtyTerminals: no terminals found after waiting');
  return false;
}

/**
 * Create all queued terminals from cmux-pty state_sync.
 * This should be called after waitForCmuxPtyTerminal() confirms terminals exist.
 * Directly creates the vscode terminals without going through provideTerminalProfile.
 * Focuses the "cmux" terminal if found, or the first available terminal.
 */
export async function createQueuedTerminals(options?: { focus?: boolean }): Promise<void> {
  if (!terminalManager) return;
  console.log('[cmux] createQueuedTerminals called');
  terminalManager.drainRestoreQueue();

  // Focus the "cmux" terminal (main agent terminal) after creation
  const shouldFocus = options?.focus ?? true;
  if (!shouldFocus) {
    return;
  }

  const terminals = terminalManager.getTerminals();
  console.log(`[cmux] Have ${terminals.length} terminals after drain`);

  // First try to focus the "cmux" terminal (main agent)
  const cmuxTerminal = terminals.find(t => t.info.name === 'cmux');
  if (cmuxTerminal) {
    console.log('[cmux] Focusing cmux terminal');
    cmuxTerminal.terminal.show(false); // false = take focus
    return;
  }

  // If no "cmux" terminal, try to focus the "dev" terminal (for cloud workspaces)
  const devTerminal = terminals.find(t => t.info.name === 'dev' || t.info.metadata?.type === 'dev');
  if (devTerminal) {
    console.log('[cmux] Focusing dev terminal');
    devTerminal.terminal.show(false);
    return;
  }

  // Otherwise focus the first terminal in panel location
  const panelTerminal = terminals.find(t => t.info.metadata?.location === 'panel');
  if (panelTerminal) {
    console.log('[cmux] Focusing first panel terminal:', panelTerminal.info.name);
    panelTerminal.terminal.show(false);
    return;
  }

  // Last resort: focus any terminal
  if (terminals.length > 0) {
    console.log('[cmux] Focusing first available terminal:', terminals[0].info.name);
    terminals[0].terminal.show(false);
  }
}
