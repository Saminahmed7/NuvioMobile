package com.nuvio.app.features.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nuvio.app.core.ui.nuvio
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.compose_player_auto_sync
import nuvio.composeapp.generated.resources.compose_player_capture_line
import nuvio.composeapp.generated.resources.compose_player_loading_lines
import nuvio.composeapp.generated.resources.compose_player_no_subtitle_lines_found
import nuvio.composeapp.generated.resources.compose_player_reload
import nuvio.composeapp.generated.resources.compose_player_reset
import nuvio.composeapp.generated.resources.compose_player_select_addon_subtitle_first
import nuvio.composeapp.generated.resources.compose_player_subtitle_delay
import org.jetbrains.compose.resources.stringResource
import kotlin.math.abs

@Composable
fun SubtitleSyncPanel(
    subtitleDelayMs: Int,
    selectedAddonSubtitle: AddonSubtitle?,
    subtitleAutoSyncState: SubtitleAutoSyncUiState,
    onSubtitleDelayChanged: (Int) -> Unit,
    onSubtitleDelayReset: () -> Unit,
    onAutoSyncCapture: () -> Unit,
    onAutoSyncCueSelected: (SubtitleSyncCue) -> Unit,
    onAutoSyncReload: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
    val capturedPositionMs = subtitleAutoSyncState.capturedPositionMs
    val nearestCues = if (capturedPositionMs == null) {
        subtitleAutoSyncState.cues.take(8)
    } else {
        subtitleAutoSyncState.cues.sortedBy { abs(it.startTimeMs - capturedPositionMs) }.take(8)
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // --- 1. Manual Delay Adjustment ---
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(Res.string.compose_player_subtitle_delay),
                    color = Color.White,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = formatSubtitleDelay(subtitleDelayMs),
                    color = if (subtitleDelayMs == 0) Color.White.copy(alpha = 0.7f) else tokens.colors.accent,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
            }

            // Quick adjustment buttons: -500ms, -100ms, Reset, +100ms, +500ms
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                SyncQuickButton("-500ms", modifier = Modifier.weight(1f)) {
                    onSubtitleDelayChanged((subtitleDelayMs - 500).coerceAtLeast(SUBTITLE_DELAY_MIN_MS))
                }
                SyncQuickButton("-100ms", modifier = Modifier.weight(1f)) {
                    onSubtitleDelayChanged((subtitleDelayMs - 100).coerceAtLeast(SUBTITLE_DELAY_MIN_MS))
                }
                SyncQuickButton(
                    label = stringResource(Res.string.compose_player_reset),
                    enabled = subtitleDelayMs != 0,
                    modifier = Modifier.weight(1f),
                    onClick = onSubtitleDelayReset,
                )
                SyncQuickButton("+100ms", modifier = Modifier.weight(1f)) {
                    onSubtitleDelayChanged((subtitleDelayMs + 100).coerceAtMost(SUBTITLE_DELAY_MAX_MS))
                }
                SyncQuickButton("+500ms", modifier = Modifier.weight(1f)) {
                    onSubtitleDelayChanged((subtitleDelayMs + 500).coerceAtMost(SUBTITLE_DELAY_MAX_MS))
                }
            }
        }

        // --- 2. Interactive Dialogue Cue Matching (Yesnt system) ---
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(Res.string.compose_player_auto_sync),
                    color = Color.White,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SyncActionButton(
                        label = stringResource(Res.string.compose_player_reload),
                        enabled = selectedAddonSubtitle != null,
                        onClick = onAutoSyncReload,
                    )
                    SyncActionButton(
                        label = stringResource(Res.string.compose_player_capture_line),
                        enabled = selectedAddonSubtitle != null,
                        isPrimary = true,
                        onClick = onAutoSyncCapture,
                    )
                }
            }

            if (capturedPositionMs != null) {
                Text(
                    text = "Matched near ${formatCueTimestamp(capturedPositionMs)} — tap spoken line:",
                    color = tokens.colors.accent,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Medium,
                )
            } else if (selectedAddonSubtitle != null && !subtitleAutoSyncState.isLoading) {
                Text(
                    text = "Pause when a line is spoken and tap Capture.",
                    color = Color.White.copy(alpha = 0.6f),
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            when {
                selectedAddonSubtitle == null -> {
                    Text(
                        text = stringResource(Res.string.compose_player_select_addon_subtitle_first),
                        color = Color.White.copy(alpha = 0.5f),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                subtitleAutoSyncState.isLoading -> {
                    Text(
                        text = stringResource(Res.string.compose_player_loading_lines),
                        color = Color.White.copy(alpha = 0.7f),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                subtitleAutoSyncState.errorMessage != null -> {
                    Text(
                        text = subtitleAutoSyncState.errorMessage,
                        color = tokens.colors.danger,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                capturedPositionMs != null && nearestCues.isEmpty() -> {
                    Text(
                        text = stringResource(Res.string.compose_player_no_subtitle_lines_found),
                        color = Color.White.copy(alpha = 0.6f),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }

            nearestCues.forEach { cue ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .clickable { onAutoSyncCueSelected(cue) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Text(
                        text = formatCueTimestamp(cue.startTimeMs),
                        color = tokens.colors.accent,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = cue.text,
                        modifier = Modifier.weight(1f),
                        color = Color.White,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun SyncQuickButton(
    label: String,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tokens = MaterialTheme.nuvio
    Box(
        modifier = modifier
            .alpha(if (enabled) 1f else tokens.opacity.disabled)
            .clip(RoundedCornerShape(8.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}

@Composable
private fun SyncActionButton(
    label: String,
    enabled: Boolean = true,
    isPrimary: Boolean = false,
    onClick: () -> Unit,
) {
    val tokens = MaterialTheme.nuvio
    Box(
        modifier = Modifier
            .alpha(if (enabled) 1f else tokens.opacity.disabled)
            .clip(RoundedCornerShape(10.dp))
            .background(if (isPrimary) tokens.colors.accent.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.08f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Text(
            text = label,
            color = if (isPrimary) tokens.colors.accent else Color.White,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (isPrimary) FontWeight.Bold else FontWeight.Normal,
        )
    }
}

private fun formatSubtitleDelay(delayMs: Int): String {
    val sign = if (delayMs >= 0) "+" else "-"
    val absoluteMs = abs(delayMs)
    val seconds = absoluteMs / 1000
    val millis = absoluteMs % 1000
    return "$sign$seconds.${millis.toString().padStart(3, '0')}s"
}

private fun formatCueTimestamp(timeMs: Long): String {
    val totalSeconds = (timeMs / 1000L).coerceAtLeast(0L)
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "$minutes:${seconds.toString().padStart(2, '0')}"
}
