// Exposes `ruby_gte_3_3` & co. as cfg flags so the GVL instrumentation is only
// compiled against Rubies that ship the thread-event + thread-specific APIs.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rb_sys_env::activate()?;
    Ok(())
}
