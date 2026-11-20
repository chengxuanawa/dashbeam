//! Keeps an iOS transfer alive when the app is backgrounded.
//!
//! The engine reports transfer progress through `TauriEventEmitter`; this
//! module mirrors those events into a Swift `BGContinuedProcessingTask`
//! (iOS 26+). Everywhere else it is a no-op.

use std::sync::atomic::{AtomicBool, Ordering};

static SEND_ACTIVE: AtomicBool = AtomicBool::new(false);
static RECEIVE_ACTIVE: AtomicBool = AtomicBool::new(false);
static TASK_ACTIVE: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "ios")]
mod ffi {
    use std::ffi::{c_char, CString};

    extern "C" {
        fn dashbeam_bg_register();
        fn dashbeam_bg_start(title: *const c_char, subtitle: *const c_char);
        fn dashbeam_bg_update(completed: u64, total: u64);
        fn dashbeam_bg_finish(success: bool);
    }

    pub(super) fn register() {
        unsafe { dashbeam_bg_register() }
    }

    pub(super) fn start() {
        let title = CString::new("DashBeam").expect("static string");
        let subtitle = CString::new("Transferring files…").expect("static string");
        unsafe { dashbeam_bg_start(title.as_ptr(), subtitle.as_ptr()) }
    }

    pub(super) fn update(completed: u64, total: u64) {
        unsafe { dashbeam_bg_update(completed, total) }
    }

    pub(super) fn finish(success: bool) {
        unsafe { dashbeam_bg_finish(success) }
    }
}

/// Registers the iOS background-task handler. Called once during app setup.
pub fn register() {
    #[cfg(target_os = "ios")]
    ffi::register();
}

/// Observes one engine event. `payload` is the raw event payload, if any.
pub fn observe(event_name: &str, payload: Option<&str>) {
    match event_name {
        "transfer-started" => {
            SEND_ACTIVE.store(true, Ordering::SeqCst);
            ensure_started();
        }
        "receive-started" => {
            RECEIVE_ACTIVE.store(true, Ordering::SeqCst);
            ensure_started();
        }
        "transfer-progress" | "receive-progress" => {
            if let Some((completed, total)) = parse_progress(payload) {
                update(completed, total);
            }
        }
        "transfer-completed" => finish_send(true),
        "transfer-failed" => finish_send(false),
        "receive-completed" => finish_receive(true),
        _ => {}
    }
}

/// Ends the sender task on a cancel path that emits no completion event.
pub fn force_finish_sender(success: bool) {
    finish_send(success);
}

/// Ends the receiver task on a cancel path that emits no completion event.
pub fn force_finish_receiver(success: bool) {
    finish_receive(success);
}

fn ensure_started() {
    if !SEND_ACTIVE.load(Ordering::SeqCst) && !RECEIVE_ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    if TASK_ACTIVE.swap(true, Ordering::SeqCst) {
        return;
    }
    #[cfg(target_os = "ios")]
    ffi::start();
}

fn finish_send(success: bool) {
    if !SEND_ACTIVE.swap(false, Ordering::SeqCst) {
        return;
    }
    finish_if_idle(success);
}

fn finish_receive(success: bool) {
    if !RECEIVE_ACTIVE.swap(false, Ordering::SeqCst) {
        return;
    }
    finish_if_idle(success);
}

fn finish_if_idle(success: bool) {
    if SEND_ACTIVE.load(Ordering::SeqCst) || RECEIVE_ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    if !TASK_ACTIVE.swap(false, Ordering::SeqCst) {
        return;
    }
    #[cfg(target_os = "ios")]
    ffi::finish(success);
    #[cfg(not(target_os = "ios"))]
    let _ = success;
}

fn update(completed: u64, total: u64) {
    #[cfg(target_os = "ios")]
    ffi::update(completed, total);
    #[cfg(not(target_os = "ios"))]
    let _ = (completed, total);
}

/// Parses the shared `bytes:total:speed` progress payload.
fn parse_progress(payload: Option<&str>) -> Option<(u64, u64)> {
    let payload = payload?;
    let mut parts = payload.split(':');
    let completed = parts.next()?.parse().ok()?;
    let total = parts.next()?.parse().ok()?;
    Some((completed, total))
}

#[cfg(test)]
mod tests {
    use super::parse_progress;

    #[test]
    fn parses_progress_payload() {
        assert_eq!(parse_progress(Some("12:34:56000")), Some((12, 34)));
    }

    #[test]
    fn rejects_malformed_progress_payloads() {
        assert_eq!(parse_progress(None), None);
        assert_eq!(parse_progress(Some("a:34:1")), None);
        assert_eq!(parse_progress(Some("")), None);
    }
}
