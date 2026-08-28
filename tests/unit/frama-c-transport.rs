use std::io::ErrorKind;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use frama_c_mcp::error::FramaCError;
use frama_c_mcp::frama_c::transport::Transport;

/// A write that dies part-way poisons the transport, and every later frame
/// in either direction fails fast with the reason rather than waiting on
/// the dead peer.
///
/// The peer is closed rather than wedged, because the close is
/// deterministic: on Linux the next write on an AF_UNIX stream whose peer
/// is gone answers EPIPE at once, where a stalled write would need the
/// write timeout and a wall-clock budget. This is the transport half of
/// poison recovery; the session half is in
/// tests/test-transport-poison-recovery.rs.
#[tokio::test]
async fn a_failed_write_poisons_every_later_frame() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("peer-gone.sock");
    let listener = tokio::net::UnixListener::bind(&socket).expect("bind");

    let mut transport = Transport::connect(socket.to_str().expect("utf8 path"))
        .await
        .expect("connect to the listener");
    let (peer, _) = listener.accept().await.expect("accept");

    // close(2) is synchronous: once the peer drops, this stream has no
    // other end and the kernel refuses the next write rather than
    // buffering it.
    drop(peer);

    // The failing write reports the kernel's error, not the poison
    // message: poison() returns the error the caller should see, and the
    // fixed text below is for the calls after it.
    let error = transport
        .send_frame("{}")
        .await
        .expect_err("a write whose peer is gone");
    match error {
        FramaCError::Io(error) => {
            assert_eq!(error.kind(), ErrorKind::BrokenPipe, "{error}");
        }
        other => panic!("expected an io error, got {other:?}"),
    }

    assert!(
        transport.poison_flag().load(Ordering::Relaxed),
        "the failed write did not set the flag every later call checks"
    );

    // Both directions answer at once with the reason, and neither waits:
    // recv_frame is handed a budget it must not spend.
    let started = Instant::now();
    let send = transport
        .send_frame("{}")
        .await
        .expect_err("a poisoned transport accepted a frame");
    let recv = transport
        .recv_frame(Duration::from_secs(60))
        .await
        .expect_err("a poisoned transport waited for a frame");
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "poisoned calls waited on the socket: {:?}",
        started.elapsed()
    );
    for error in [send, recv] {
        match error {
            FramaCError::Io(error) => assert_eq!(
                error.to_string(),
                "transport poisoned by an incomplete frame write"
            ),
            other => panic!("expected an io error, got {other:?}"),
        }
    }
}
