package com.nuvio.app.features.player

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nuvio.app.core.ui.DialogButton
import com.nuvio.app.core.ui.DialogButtonStyle
import com.nuvio.app.core.ui.DialogButtons
import com.nuvio.app.core.ui.DialogSurface
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PlayerDiagnosticsDialog(
    launchId: Long?,
    onDismiss: () -> Unit,
) {
    val clipboardManager = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var reportText by remember { mutableStateOf("Generating diagnostic report...") }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(launchId) {
        reportText = TempPlaybackCache.getDiagnosticReport(launchId)
    }

    DialogSurface(
        onDismissRequest = onDismiss,
        title = "Playback & Cache Diagnostics",
        modifier = Modifier.fillMaxWidth(0.95f),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Live diagnostic events and cache proxy state for this playback session:",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.7f),
            )

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 120.dp, max = 320.dp)
                    .background(Color.Black.copy(alpha = 0.65f), shape = RoundedCornerShape(8.dp))
                    .border(0.5.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(8.dp))
                    .padding(8.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                SelectionContainer {
                    Text(
                        text = reportText,
                        color = Color(0xFF81C784),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        lineHeight = 15.sp,
                    )
                }
            }

            DialogButtons {
                DialogButton(
                    text = if (copied) "✓ Copied to Clipboard" else "Copy Report",
                    onClick = {
                        clipboardManager.setText(AnnotatedString(reportText))
                        copied = true
                        scope.launch {
                            delay(2500)
                            copied = false
                        }
                    },
                    style = DialogButtonStyle.Primary,
                )
                DialogButton(
                    text = "Close",
                    onClick = onDismiss,
                    style = DialogButtonStyle.Secondary,
                )
            }
        }
    }
}
