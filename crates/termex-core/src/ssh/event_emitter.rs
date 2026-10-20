use std::sync::Arc;

/// Abstracts SSH event emission, decoupling the SSH core from the UI runtime.
///
/// The concrete implementation is `FrbSshEmitter` in
/// `termex-flutter-bridge`, which pushes to an FRB `StreamSink`.
#[async_trait::async_trait]
pub trait SshEventEmitter: Send + Sync + 'static {
    /// Push terminal stdout bytes to the frontend.
    fn emit_stdout(&self, session_id: &str, data: Vec<u8>);

    /// Notify that the channel exited with the given status code.
    fn emit_exit_status(&self, session_id: &str, exit_code: u32);

    /// Notify that the connection was closed (EOF or disconnect).
    fn emit_disconnected(&self, session_id: &str);

    /// Emit a named event for reverse port-forward notifications (git-sync, exit proxy).
    /// Default implementation is a no-op so FRB emitter needs no override.
    fn emit_port_forward_event(&self, _event: &str, _payload: &str) {}

    /// Called once per inbound data chunk before `emit_stdout`, for optional
    /// side effects (e.g. session recording). Default is a no-op.
    async fn on_data_side_effect(&self, _session_id: &str, _data: &[u8]) {}
}

/// Convenience alias used throughout the SSH module.
pub type BoxedEmitter = Arc<dyn SshEventEmitter>;
