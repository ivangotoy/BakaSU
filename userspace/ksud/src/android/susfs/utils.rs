/// Write a &str to a C-style char array; a value that does not fit with its NUL (or holds a
/// NUL) is refused instead of being cut, which would make SUSFS act on another path.
pub fn str_to_c_array<const N: usize>(s: &str, array: &mut [u8; N]) -> anyhow::Result<()> {
    let bytes = s.as_bytes();
    anyhow::ensure!(
        bytes.len() < N && !bytes.contains(&0),
        "value longer than {} bytes or containing NUL: {s:?}",
        N - 1
    );
    array[..bytes.len()].copy_from_slice(bytes);
    array[bytes.len()] = 0;
    Ok(())
}

/// Get a string from C-style char*
pub fn c_array_to_string<const N: usize>(array: &[u8; N]) -> String {
    let len = array.iter().position(|&x| x == 0).unwrap_or(N);
    let bytes = &array[..len].to_vec();
    String::from_utf8(bytes.to_vec()).unwrap_or_else(|_| "<invalid>".to_string())
}
