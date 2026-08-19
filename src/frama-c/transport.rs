use bytes::{Buf, BufMut, BytesMut};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use super::codec;
use crate::error::FramaCError;

pub struct Transport {
    stream: UnixStream,
    read_buf: BytesMut,
}

impl Transport {
    pub async fn connect(path: &str) -> Result<Self, FramaCError> {
        let stream = UnixStream::connect(path).await?;
        Ok(Transport {
            stream,
            read_buf: BytesMut::with_capacity(8192),
        })
    }

    pub async fn send_frame(&mut self, payload: &str) -> Result<(), FramaCError> {
        let frame = codec::encode_frame(payload);
        self.stream.write_all(&frame).await?;
        Ok(())
    }

    pub async fn recv_frame(
        &mut self,
        timeout: Duration,
    ) -> Result<Option<String>, FramaCError> {
        loop {
            if let Some((payload, consumed)) = codec::decode_frame(&self.read_buf)? {
                self.read_buf.advance(consumed);
                return Ok(Some(payload));
            }
            let mut tmp = [0u8; 4096];
            match tokio::time::timeout(timeout, self.stream.read(&mut tmp)).await {
                Ok(Ok(0)) => {
                    return Err(FramaCError::Io(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "connection closed",
                    )));
                }
                Ok(Ok(n)) => {
                    self.read_buf.put_slice(&tmp[..n]);
                }
                Ok(Err(e)) => return Err(FramaCError::Io(e)),
                Err(_) => return Ok(None),
            }
        }
    }

    pub async fn close(&mut self) -> Result<(), FramaCError> {
        self.stream.shutdown().await?;
        Ok(())
    }
}
