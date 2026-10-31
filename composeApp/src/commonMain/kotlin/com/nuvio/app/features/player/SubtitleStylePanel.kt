package com.nuvio.app.features.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.compose_player_style
import nuvio.composeapp.generated.resources.subtitle_reset_appearance
import org.jetbrains.compose.resources.stringResource

@Composable
fun SubtitleStylePanel(
    style: SubtitleStyleState,
    isCompact: Boolean,
    showHeader: Boolean = true,
    onStyleChanged: (SubtitleStyleState) -> Unit,
) {
    val sectionGap = if (isCompact) 12.dp else 16.dp

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(sectionGap),
    ) {
        if (showHeader) {
            Text(
                text = stringResource(Res.string.compose_player_style),
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
            )
        }

        SubtitleAppearanceControls(
            style = style,
            spacing = sectionGap,
            onStyleChanged = onStyleChanged,
        )

        Text(
            text = stringResource(Res.string.subtitle_reset_appearance),
            modifier = Modifier
                .clip(RoundedCornerShape(12.dp))
                .clickable { onStyleChanged(style.resetAppearance()) }
                .padding(horizontal = 12.dp, vertical = 10.dp),
            color = Color.White,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
internal fun SubtitleStyleSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = title,
            color = Color.White,
            style = MaterialTheme.typography.bodyMedium,
        )
        content()
    }
}

@Composable
internal fun SubtitleStyleStepper(
    value: String,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
    valueWidth: Dp = 84.dp,
    enabled: Boolean = true,
) {
    Row(
        modifier = Modifier.alpha(if (enabled) 1f else 0.42f),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SubtitleStepperButton(
            icon = Icons.Rounded.Remove,
            onClick = onDecrease,
            enabled = enabled,
        )
        Box(
            modifier = Modifier
                .widthIn(min = valueWidth)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = 0.06f))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = value,
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        SubtitleStepperButton(
            icon = Icons.Rounded.Add,
            onClick = onIncrease,
            enabled = enabled,
        )
    }
}

@Composable
private fun SubtitleStepperButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    enabled: Boolean,
) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(20.dp),
        )
    }
}
