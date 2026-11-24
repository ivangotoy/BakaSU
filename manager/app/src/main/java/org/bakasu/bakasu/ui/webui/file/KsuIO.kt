package org.bakasu.bakasu.ui.webui.file

import android.webkit.JavascriptInterface
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap

const val TAG = "KsuIO"

/** File access of one WebUI (`ksu.io()`): its streams close with that WebUI. */
class KsuIO {
    internal val openInputStreams = ConcurrentHashMap<String, ManagedInputStream>()
    internal val openOutputStreams = ConcurrentHashMap<String, OutputStream>()

    private val fileOutputStream = FileOutputStreamInterface(this)
    private val fileInputStream = FileInputStreamInterface(this)
    private val randomAccessFile = RandomAccessFileInterface()

    @JavascriptInterface
    fun version(): Int = KSU_IO_VERSION

    @JavascriptInterface
    @Suppress("ktlint:standard:function-naming")
    fun File(path: String): FileInterface = FileInterface(path, this)

    @JavascriptInterface
    @Suppress("ktlint:standard:function-naming")
    fun FileInputStream(): FileInputStreamInterface = fileInputStream

    @JavascriptInterface
    @Suppress("ktlint:standard:function-naming")
    fun FileOutputStream(): FileOutputStreamInterface = fileOutputStream

    @JavascriptInterface
    @Suppress("ktlint:standard:function-naming")
    fun RandomAccessFile(): RandomAccessFileInterface = randomAccessFile

    /**
     * Check if we can open a new stream without exceeding resource limits.
     * Returns true if under limit, false otherwise.
     */
    internal fun canOpenStream(): Boolean = openInputStreams.size + openOutputStreams.size < MAX_OPEN_STREAMS

    fun destroy() {
        fileInputStream.closeAll()
        fileOutputStream.closeAll()
        randomAccessFile.closeAll()
    }

    private companion object {
        const val KSU_IO_VERSION = 1
        const val MAX_OPEN_STREAMS = 50
    }
}
