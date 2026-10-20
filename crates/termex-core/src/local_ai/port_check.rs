//! Port-listening helpers extracted from the legacy `health_check.rs` so
//! they can be reused without an `AppState` dependency. The full
//! AppState-aware health/restart loop belonged to the removed Tauri shell.

use std::net::TcpStream;
use std::time::Duration;
use tokio::time::sleep;

/// Returns `true` if the given port accepts a TCP connection on any of the
/// local loopback addresses.
pub async fn is_port_listening(port: u16) -> bool {
    if TcpStream::connect(("127.0.0.1", port)).is_ok() {
        return true;
    }
    if TcpStream::connect(("localhost", port)).is_ok() {
        return true;
    }
    if TcpStream::connect(("0.0.0.0", port)).is_ok() {
        return true;
    }
    false
}

/// Waits up to `max_wait_secs` seconds for `port` to start accepting
/// connections, retrying with exponential backoff.
pub async fn wait_for_port(port: u16, max_wait_secs: u64) -> Result<(), String> {
    let start = std::time::Instant::now();
    let max_duration = Duration::from_secs(max_wait_secs);
    let mut attempt = 0u32;

    loop {
        if is_port_listening(port).await {
            return Ok(());
        }
        if start.elapsed() > max_duration {
            return Err(format!(
                "Timeout waiting for port {port} to listen (waited {max_wait_secs} seconds)"
            ));
        }

        // Exponential backoff capped at 300ms: 10, 20, 40, 80, 160, 300, 300, ...
        let capped = std::cmp::min(attempt, 5);
        let backoff_ms = std::cmp::min(10 * (1u64 << capped), 300);
        sleep(Duration::from_millis(backoff_ms)).await;
        attempt += 1;
    }
}
