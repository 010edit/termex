use std::sync::Arc;

/// Abstracts SFTP transfer-progress event emission, decoupling the SFTP
/// core from the UI runtime.
///
/// The concrete implementation is `FrbSftpEmitter` in
/// `termex-flutter-bridge`, which pushes to a per-transfer queue.
pub trait SftpEventEmitter: Send + Sync + 'static {
    /// Called periodically during a file transfer with cumulative progress.
    fn emit_progress(&self, transfer_id: &str, remote_path: &str, transferred: u64, total: u64);

    /// Called once when a transfer finishes successfully.
    fn emit_done(&self, transfer_id: &str, remote_path: &str, total: u64);

    /// Called if the transfer fails mid-stream. Default is a no-op.
    fn emit_error(&self, _transfer_id: &str, _error: &str) {}
}

/// Convenience alias used throughout the SFTP module.
pub type BoxedSftpEmitter = Arc<dyn SftpEventEmitter>;
