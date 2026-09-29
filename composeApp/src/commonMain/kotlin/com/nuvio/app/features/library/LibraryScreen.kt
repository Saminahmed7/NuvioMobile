package com.nuvio.app.features.library

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.ViewAgenda
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.DisintegratingContainer
import com.nuvio.app.core.ui.NuvioStatusModal
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.core.ui.posterCardClickable
import com.nuvio.app.features.downloads.DownloadItem
import com.nuvio.app.features.downloads.DownloadStatus
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.downloads.DownloadsUiState
import com.nuvio.app.features.downloads.sortedForSeriesDownloads
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.foundation.gestures.stopScroll
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.ScreenActivityEffect
import com.nuvio.app.core.i18n.localizedByteUnit
import com.nuvio.app.core.network.NetworkCondition
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.ui.DisintegrationRequest
import com.nuvio.app.core.ui.NuvioDropdownChip
import com.nuvio.app.core.ui.NuvioDropdownOption
import com.nuvio.app.core.ui.NuvioNetworkOfflineCard
import com.nuvio.app.core.ui.NuvioScreen
import com.nuvio.app.core.ui.NuvioScreenHeader
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.NuvioViewAllPillSize
import com.nuvio.app.core.ui.ScopedDisintegrationTracker
import com.nuvio.app.core.ui.SkeletonBlock
import com.nuvio.app.core.ui.nuvioConsumePointerEvents
import com.nuvio.app.core.ui.shimmer
import com.nuvio.app.features.cloud.CloudLibraryFile
import com.nuvio.app.features.cloud.CloudLibraryItem
import com.nuvio.app.features.cloud.CloudLibraryItemType
import com.nuvio.app.features.cloud.CloudLibraryRepository
import com.nuvio.app.features.cloud.CloudLibraryUiState
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.home.components.HomeEmptyStateCard
import com.nuvio.app.features.home.components.HomePosterCard
import com.nuvio.app.features.home.components.HomeSkeletonRow
import com.nuvio.app.features.home.components.posterGridColumnCountForWidth
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watching.application.WatchingState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import nuvio.composeapp.generated.resources.*
import org.jetbrains.compose.resources.stringResource

@Composable
fun LibraryScreen(
    modifier: Modifier = Modifier,
    scrollToTopRequests: Flow<Unit> = emptyFlow(),
    onPosterClick: ((LibraryItem) -> Unit)? = null,
    onPosterLongClick: ((LibraryItem, LibrarySection) -> Unit)? = null,
    onSectionViewAllClick: ((LibrarySection, LibrarySortOption) -> Unit)? = null,
    onCloudFilePlay: ((CloudLibraryItem, CloudLibraryFile) -> Unit)? = null,
    onConnectCloudClick: (() -> Unit)? = null,
    onDownloadsClick: (() -> Unit)? = null,
    onOpenDownload: ((DownloadItem) -> Unit)? = null,
    disintegrationRequest: DisintegrationRequest<String>? = null,
) {
    val uiState by remember {
        LibraryRepository.ensureLoaded()
        LibraryRepository.uiState
    }.collectAsStateWithLifecycle()
    val downloadsUiState by remember {
        DownloadsRepository.ensureLoaded()
        DownloadsRepository.uiState
    }.collectAsStateWithLifecycle()
    val cloudUiState by CloudLibraryRepository.uiState.collectAsStateWithLifecycle()
    val cloudSettings by remember {
        DebridSettingsRepository.ensureLoaded()
        DebridSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val watchedUiState by remember {
        WatchedRepository.ensureLoaded()
        WatchedRepository.uiState
    }.collectAsStateWithLifecycle()
    val fullyWatchedSeriesKeys by WatchedRepository.fullyWatchedSeriesKeys.collectAsStateWithLifecycle()
    val displaySettings by remember {
        LibraryDisplaySettingsRepository.ensureLoaded()
        LibraryDisplaySettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val networkStatusUiState by NetworkStatusRepository.uiState.collectAsStateWithLifecycle()
    var observedOfflineState by remember { mutableStateOf(false) }
    var sourceModeName by rememberSaveable { mutableStateOf(LibraryViewMode.Saved.name) }
    val sourceMode = remember(sourceModeName) {
        runCatching { LibraryViewMode.valueOf(sourceModeName) }.getOrDefault(LibraryViewMode.Saved)
    }
    var downloadsFilterName by rememberSaveable { mutableStateOf(LibraryDownloadsFilter.All.name) }
    val downloadsFilter = remember(downloadsFilterName) {
        runCatching { LibraryDownloadsFilter.valueOf(downloadsFilterName) }
            .getOrDefault(LibraryDownloadsFilter.All)
    }
    var selectedDownloadsGenre by rememberSaveable { mutableStateOf<String?>(null) }
    var downloadPendingDeletionTarget by remember { mutableStateOf<LibraryDownloadActionTarget?>(null) }
    var selectedProviderId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedTypeName by rememberSaveable { mutableStateOf<String?>(null) }
    var cloudSearchQuery by rememberSaveable { mutableStateOf("") }
    val selectedType = remember(selectedTypeName) {
        selectedTypeName?.let { runCatching { CloudLibraryItemType.valueOf(it) }.getOrNull() }
    }
    var selectedCloudItemKey by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedLibrarySectionKey by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedLibraryType by rememberSaveable { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    ScreenActivityEffect(listState) { screenActive ->
        if (!screenActive) listState.stopScroll()
    }
    val isRemoteSource = uiState.sourceMode != LibrarySourceMode.LOCAL
    val effectiveSortOption = effectiveLibrarySortOption(
        selected = displaySettings.sortOption,
        sourceMode = uiState.sourceMode,
    )
    val orderListKeys = if (sourceMode != LibraryViewMode.Saved) emptyList() else {
        if (displaySettings.layoutMode == LibraryLayoutMode.HORIZONTAL) uiState.sections.map { it.type }
        else listOfNotNull(uiState.sections.firstOrNull { it.type == selectedLibrarySectionKey }?.type
            ?: uiState.sections.firstOrNull()?.type)
    }
    val providerOrders = rememberLibraryProviderOrders(uiState.sourceMode, orderListKeys, effectiveSortOption)
    val visibleSortOption = if (providerOrders.failed) LibrarySortOption.DEFAULT else effectiveSortOption
    val sortedSections = remember(uiState.sections, displaySettings, uiState.sourceMode, sourceMode, providerOrders) {
        if (sourceMode == LibraryViewMode.Saved && displaySettings.layoutMode == LibraryLayoutMode.HORIZONTAL) {
            sortLibrarySections(
                sections = uiState.sections,
                selected = visibleSortOption,
                sourceMode = uiState.sourceMode,
                providerOrders = providerOrders.ranks,
            )
        } else {
            emptyList()
        }
    }
    val verticalProjection = remember(
        uiState.sections,
        uiState.sourceMode,
        selectedLibrarySectionKey,
        selectedLibraryType,
        displaySettings,
        sourceMode,
        providerOrders,
    ) {
        if (sourceMode == LibraryViewMode.Saved && displaySettings.layoutMode == LibraryLayoutMode.VERTICAL) {
            buildLibraryVerticalProjection(
                sections = uiState.sections,
                sourceMode = uiState.sourceMode,
                selectedSectionKey = selectedLibrarySectionKey,
                selectedType = selectedLibraryType,
                sortOption = visibleSortOption,
                providerOrders = providerOrders.ranks,
            )
        } else {
            LibraryVerticalProjection(
                availableSections = emptyList(),
                selectedSectionKey = null,
                availableTypes = emptyList(),
                selectedType = null,
                entries = emptyList(),
            )
        }
    }
    val retryLibraryLoad: () -> Unit = {
        NetworkStatusRepository.requestRefresh(force = true)
        coroutineScope.launch {
            LibraryRepository.pullFromServer(
                profileId = ProfileRepository.activeProfileId,
                refreshIntent = TrackingRefreshIntent.USER_INITIATED,
            )
        }
    }

    ScreenActivityEffect(networkStatusUiState.condition, isRemoteSource) { screenActive ->
        if (!screenActive) return@ScreenActivityEffect
        when (networkStatusUiState.condition) {
            NetworkCondition.NoInternet,
            NetworkCondition.ServersUnreachable,
            -> {
                observedOfflineState = true
            }

            NetworkCondition.Online -> {
                if (!observedOfflineState) return@ScreenActivityEffect
                observedOfflineState = false
                if (isRemoteSource) {
                    coroutineScope.launch {
                        LibraryRepository.pullFromServer(ProfileRepository.activeProfileId)
                    }
                }
            }

            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> Unit
        }
    }

    ScreenActivityEffect(scrollToTopRequests) { screenActive ->
        if (!screenActive) return@ScreenActivityEffect
        scrollToTopRequests.collect {
            listState.animateScrollToItem(0)
        }
    }

    ScreenActivityEffect(sourceMode, cloudSettings.cloudLibraryEnabled, cloudSettings.providerApiKeys) { screenActive ->
        if (screenActive && sourceMode == LibraryViewMode.Cloud) {
            CloudLibraryRepository.ensureLoaded()
            selectedCloudItemKey = null
        }
    }

    val disintegration = remember { LibraryDisintegrationHolder() }
    val librarySectionsDisplay = if (
        sourceMode == LibraryViewMode.Saved &&
        displaySettings.layoutMode == LibraryLayoutMode.HORIZONTAL &&
        uiState.isLoaded &&
        sortedSections.isNotEmpty()
    ) {
        disintegration.sync(
            sourceMode = uiState.sourceMode,
            sections = sortedSections,
            previewLimit = LIBRARY_SECTION_PREVIEW_LIMIT,
            request = disintegrationRequest,
        )
    } else {
        disintegration.reset()
        emptyList()
    }

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val gridColumns = remember(maxWidth) { posterGridColumnCountForWidth(maxWidth) }

        NuvioScreen(
            modifier = Modifier.fillMaxSize(),
            horizontalPadding = 0.dp,
            listState = listState,
        ) {
            stickyHeader {
                Box(modifier = Modifier.fillMaxWidth()) {
                    Box(
                        modifier = Modifier
                            .matchParentSize()
                            .background(MaterialTheme.colorScheme.background)
                            .nuvioConsumePointerEvents(),
                    )
                    androidx.compose.foundation.layout.Column(
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        NuvioScreenHeader(
                            title = when (sourceMode) {
                                LibraryViewMode.Cloud -> stringResource(Res.string.library_title)
                                LibraryViewMode.Downloads -> stringResource(Res.string.compose_settings_root_downloads_title)
                                LibraryViewMode.Saved -> when (uiState.sourceMode) {
                                    LibrarySourceMode.LOCAL -> stringResource(Res.string.library_title)
                                    LibrarySourceMode.TRAKT -> stringResource(Res.string.library_trakt_title)
                                    LibrarySourceMode.SIMKL -> stringResource(Res.string.library_simkl_title)
                                    LibrarySourceMode.MDBLIST -> stringResource(Res.string.library_mdblist_title)
                                }
                            },
                            modifier = Modifier.padding(horizontal = 16.dp),
                            actions = {
                                if (sourceMode == LibraryViewMode.Saved) {
                                    LibraryListManagementButton()
                                    val targetLayout = if (displaySettings.layoutMode == LibraryLayoutMode.HORIZONTAL) {
                                        LibraryLayoutMode.VERTICAL
                                    } else {
                                        LibraryLayoutMode.HORIZONTAL
                                    }
                                    IconButton(
                                        onClick = {
                                            LibraryDisplaySettingsRepository.setLayoutMode(targetLayout)
                                        },
                                    ) {
                                        Crossfade(
                                            targetState = targetLayout,
                                            animationSpec = tween(durationMillis = 140),
                                            label = "libraryLayoutAction",
                                        ) { animatedTargetLayout ->
                                            Icon(
                                                imageVector = if (animatedTargetLayout == LibraryLayoutMode.VERTICAL) {
                                                    Icons.Rounded.GridView
                                                } else {
                                                    Icons.Rounded.ViewAgenda
                                                },
                                                contentDescription = if (animatedTargetLayout == LibraryLayoutMode.VERTICAL) {
                                                    stringResource(Res.string.library_layout_show_vertical)
                                                } else {
                                                    stringResource(Res.string.library_layout_show_horizontal)
                                                },
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                    }
                                }
                                if (onDownloadsClick != null && sourceMode != LibraryViewMode.Downloads) {
                                    LibraryDownloadsButton(onClick = onDownloadsClick)
                                }
                            },
                        )
                        LibrarySourceSwitch(
                            selectedMode = sourceMode,
                            onModeSelected = { mode ->
                                sourceModeName = mode.name
                            },
                            modifier = Modifier.padding(horizontal = 16.dp),
                        )
                        Spacer(modifier = Modifier.height(6.dp))
                    }
                }
            }

            if (sourceMode == LibraryViewMode.Cloud) {
                cloudLibraryContent(
                    uiState = cloudUiState,
                    selectedProviderId = selectedProviderId,
                    selectedType = selectedType,
                    selectedCloudItemKey = selectedCloudItemKey,
                    searchQuery = cloudSearchQuery,
                    onSearchQueryChange = {
                        cloudSearchQuery = it
                        selectedCloudItemKey = null
                    },
                    onProviderSelected = {
                        selectedProviderId = it
                        selectedTypeName = null
                        selectedCloudItemKey = null
                    },
                    onTypeSelected = {
                        selectedTypeName = it?.name
                        selectedCloudItemKey = null
                    },
                    onItemSelected = { item ->
                        val playableFiles = item.playableFiles
                        when {
                            playableFiles.size == 1 -> onCloudFilePlay?.invoke(item, playableFiles.first())
                            playableFiles.size > 1 -> selectedCloudItemKey = item.stableKey
                        }
                    },
                    onFileSelected = { item, file -> onCloudFilePlay?.invoke(item, file) },
                    onBackToItems = { selectedCloudItemKey = null },
                    onRefresh = { CloudLibraryRepository.refresh() },
                    onConnectCloudClick = onConnectCloudClick,
                )
            } else if (sourceMode == LibraryViewMode.Downloads) {
                downloadsLibraryContent(
                    uiState = downloadsUiState,
                    selectedFilter = downloadsFilter,
                    selectedGenre = selectedDownloadsGenre,
                    onFilterSelected = { filter ->
                        downloadsFilterName = filter.name
                        selectedDownloadsGenre = null
                    },
                    onGenreSelected = { genre ->
                        selectedDownloadsGenre = genre
                    },
                    onPosterClick = onPosterClick,
                    onOpenDownload = onOpenDownload,
                    onDownloadLongClick = { target ->
                        downloadPendingDeletionTarget = target
                    },
                )
            } else {
                when {
                    !uiState.isLoaded || (uiState.isLoading && uiState.sections.isEmpty()) -> {
                        if (displaySettings.layoutMode == LibraryLayoutMode.VERTICAL) {
                            libraryVerticalSkeletonItems(gridColumns)
                        } else {
                            items(3) {
                                HomeSkeletonRow(
                                    horizontalPadding = 16.dp,
                                )
                            }
                        }
                    }

                    !uiState.errorMessage.isNullOrBlank() && uiState.sections.isEmpty() -> {
                        item {
                            if (networkStatusUiState.isOfflineLike) {
                                NuvioNetworkOfflineCard(
                                    condition = networkStatusUiState.condition,
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    onRetry = retryLibraryLoad,
                                )
                            } else {
                                HomeEmptyStateCard(
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    title = when (uiState.sourceMode) {
                                        LibrarySourceMode.LOCAL -> stringResource(Res.string.library_load_failed)
                                        LibrarySourceMode.TRAKT -> stringResource(Res.string.library_trakt_load_failed)
                                        LibrarySourceMode.SIMKL -> stringResource(Res.string.library_simkl_load_failed)
                                        LibrarySourceMode.MDBLIST -> stringResource(Res.string.library_mdblist_load_failed)
                                    },
                                    message = uiState.errorMessage.orEmpty(),
                                    actionLabel = stringResource(Res.string.action_retry),
                                    onActionClick = retryLibraryLoad,
                                )
                            }
                        }
                    }

                    uiState.sections.isEmpty() -> {
                        item {
                            HomeEmptyStateCard(
                                modifier = Modifier.padding(horizontal = 16.dp),
                                title = when (uiState.sourceMode) {
                                    LibrarySourceMode.LOCAL -> stringResource(Res.string.library_empty_title)
                                    LibrarySourceMode.TRAKT -> stringResource(Res.string.library_trakt_empty_title)
                                    LibrarySourceMode.SIMKL -> stringResource(Res.string.library_simkl_empty_title)
                                    LibrarySourceMode.MDBLIST -> stringResource(Res.string.library_mdblist_empty_title)
                                },
                                message = when (uiState.sourceMode) {
                                    LibrarySourceMode.LOCAL -> stringResource(Res.string.library_empty_message)
                                    LibrarySourceMode.TRAKT -> stringResource(Res.string.library_trakt_empty_message)
                                    LibrarySourceMode.SIMKL -> stringResource(Res.string.library_simkl_empty_message)
                                    LibrarySourceMode.MDBLIST -> stringResource(Res.string.library_mdblist_empty_message)
                                },
                            )
                        }
                    }

                    else -> {
                        item(
                            key = "library-saved-controls:${uiState.sourceMode}:" +
                                "${displaySettings.layoutMode}:$effectiveSortOption",
                        ) {
                            LibrarySavedControls(
                                layoutMode = displaySettings.layoutMode,
                                sourceMode = uiState.sourceMode,
                                sortOption = effectiveSortOption,
                                verticalProjection = verticalProjection,
                                onSectionSelected = { sectionKey ->
                                    selectedLibrarySectionKey = sectionKey
                                    selectedLibraryType = null
                                },
                                onTypeSelected = { type -> selectedLibraryType = type },
                                onSortSelected = LibraryDisplaySettingsRepository::setSortOption,
                                modifier = libraryContentTransitionModifier()
                                    .padding(horizontal = 16.dp),
                            )
                        }
                        when (displaySettings.layoutMode) {
                            LibraryLayoutMode.HORIZONTAL -> librarySections(
                                displaySections = librarySectionsDisplay,
                                watchedKeys = watchedUiState.watchedKeys,
                                fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                                sortOption = effectiveSortOption,
                                onPosterClick = onPosterClick,
                                onSectionViewAllClick = onSectionViewAllClick,
                                onPosterLongClick = onPosterLongClick,
                                onDisintegrated = disintegration::onExited,
                            )
                            LibraryLayoutMode.VERTICAL -> libraryVerticalContent(
                                projection = verticalProjection,
                                columns = gridColumns,
                                watchedKeys = watchedUiState.watchedKeys,
                                fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                                onPosterClick = onPosterClick,
                                onPosterLongClick = onPosterLongClick,
                            )
                        }
                    }
                }
            }
        }
    }

    val pendingDeletion = downloadPendingDeletionTarget
    if (pendingDeletion != null) {
        val count = pendingDeletion.downloads.size
        val message = if (count > 1) {
            "Delete all $count downloaded episodes of \"${pendingDeletion.primaryDownload.title}\"?"
        } else {
            stringResource(Res.string.action_delete_confirm_message)
        }
        NuvioStatusModal(
            title = stringResource(Res.string.action_delete_confirm_title),
            message = message,
            isVisible = true,
            destructive = true,
            confirmText = stringResource(Res.string.action_yes),
            dismissText = stringResource(Res.string.action_no),
            onConfirm = {
                pendingDeletion.downloads.forEach { item ->
                    DownloadsRepository.cancelDownload(item.id)
                }
                downloadPendingDeletionTarget = null
            },
            onDismiss = { downloadPendingDeletionTarget = null },
        )
    }
}

private fun LazyListScope.cloudLibraryContent(
    uiState: CloudLibraryUiState,
    selectedProviderId: String?,
    selectedType: CloudLibraryItemType?,
    selectedCloudItemKey: String?,
    searchQuery: String,
    onSearchQueryChange: (String) -> Unit,
    onProviderSelected: (String?) -> Unit,
    onTypeSelected: (CloudLibraryItemType?) -> Unit,
    onItemSelected: (CloudLibraryItem) -> Unit,
    onFileSelected: (CloudLibraryItem, CloudLibraryFile) -> Unit,
    onBackToItems: () -> Unit,
    onRefresh: () -> Unit,
    onConnectCloudClick: (() -> Unit)?,
) {
    when {
        !uiState.isLoaded -> {
            cloudLibrarySkeletonItems()
        }

        !uiState.isEnabled -> {
            item {
                HomeEmptyStateCard(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    title = stringResource(Res.string.cloud_library_disabled_title),
                    message = stringResource(Res.string.cloud_library_disabled_message),
                    actionLabel = stringResource(Res.string.cloud_library_disabled_action),
                    onActionClick = onConnectCloudClick,
                )
            }
        }

        !uiState.hasConnectedProvider -> {
            item {
                HomeEmptyStateCard(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    title = stringResource(Res.string.cloud_library_connect_title),
                    message = stringResource(Res.string.cloud_library_connect_message),
                    actionLabel = stringResource(Res.string.cloud_library_connect_action),
                    onActionClick = onConnectCloudClick,
                )
            }
        }

        else -> {
            val providerItems = uiState.items
                .filter { item -> selectedProviderId == null || item.providerId == selectedProviderId }
            val availableTypes = providerItems
                .map { item -> item.type }
                .distinct()
                .sortedBy { type -> type.ordinal }
            val effectiveSelectedType = selectedType?.takeIf { type -> type in availableTypes }
            val typeFilteredItems = providerItems
                .filter { item -> effectiveSelectedType == null || item.type == effectiveSelectedType }
            // Local filter over the already-loaded library. Matches the item name or any of its
            // file names, since the useful identifier is often in the filename, not the title.
            val trimmedQuery = searchQuery.trim()
            val hasActiveFilter = selectedProviderId != null || effectiveSelectedType != null || trimmedQuery.isNotEmpty()
            val filteredItems = if (trimmedQuery.isEmpty()) {
                typeFilteredItems
            } else {
                typeFilteredItems.filter { item ->
                    item.name.contains(trimmedQuery, ignoreCase = true) ||
                        item.files.any { file -> file.name.contains(trimmedQuery, ignoreCase = true) }
                }
            }
            val selectedItem = filteredItems.firstOrNull { it.stableKey == selectedCloudItemKey }

            if (selectedItem != null) {
                item {
                    CloudLibraryFilePicker(
                        item = selectedItem,
                        onBack = onBackToItems,
                        onFileSelected = { file -> onFileSelected(selectedItem, file) },
                    )
                }
            } else {
                item {
                    CloudLibraryToolbar(
                        uiState = uiState,
                        selectedProviderId = selectedProviderId,
                        selectedType = effectiveSelectedType,
                        availableTypes = availableTypes,
                        onProviderSelected = onProviderSelected,
                        onTypeSelected = onTypeSelected,
                        onRefresh = onRefresh,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }

                item(key = "cloud-library-search") {
                    CloudLibrarySearchField(
                        query = searchQuery,
                        onQueryChange = onSearchQueryChange,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }

                val visibleProviderStates = uiState.providers.filter { providerState ->
                    selectedProviderId == null || providerState.providerId == selectedProviderId
                }
                val failedProviderStates = visibleProviderStates.filter { providerState ->
                    !providerState.errorMessage.isNullOrBlank() && providerState.items.isEmpty()
                }
                failedProviderStates.forEach { providerState ->
                    item(key = "cloud-error-${providerState.providerId}") {
                        HomeEmptyStateCard(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            title = stringResource(Res.string.cloud_library_load_failed, providerState.providerName),
                            message = providerState.errorMessage.orEmpty(),
                            actionLabel = stringResource(Res.string.action_retry),
                            onActionClick = onRefresh,
                        )
                    }
                }

                if (uiState.isRefreshing && filteredItems.isEmpty()) {
                    cloudLibrarySkeletonItems()
                } else if (filteredItems.isEmpty() && failedProviderStates.isEmpty()) {
                    item {
                        HomeEmptyStateCard(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            title = stringResource(
                                if (hasActiveFilter) {
                                    Res.string.cloud_library_no_matches_title
                                } else {
                                    Res.string.cloud_library_empty_title
                                },
                            ),
                            message = stringResource(
                                if (hasActiveFilter) {
                                    Res.string.cloud_library_no_matches_message
                                } else {
                                    Res.string.cloud_library_empty_message
                                },
                            ),
                            actionLabel = if (hasActiveFilter) null else stringResource(Res.string.action_retry),
                            onActionClick = if (hasActiveFilter) null else onRefresh,
                        )
                    }
                } else {
                    items(
                        items = filteredItems,
                        key = { item -> item.stableKey },
                    ) { item ->
                        CloudLibraryRow(
                            item = item,
                            onClick = { onItemSelected(item) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudLibrarySearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = modifier.fillMaxWidth(),
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        placeholder = { Text(stringResource(Res.string.cloud_library_search_label)) },
        leadingIcon = {
            Icon(
                imageVector = Icons.Rounded.Search,
                contentDescription = null,
            )
        },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = stringResource(Res.string.compose_search_clear),
                    )
                }
            }
        },
    )
}

private fun LazyListScope.cloudLibrarySkeletonItems() {
    item(key = "cloud-library-skeleton-toolbar") {
        CloudLibrarySkeletonToolbar(
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
    items(3) {
        CloudLibrarySkeletonRow()
    }
}

@Composable
private fun LibrarySourceSwitch(
    selectedMode: LibraryViewMode,
    onModeSelected: (LibraryViewMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LibraryChip(
            label = stringResource(Res.string.library_source_saved),
            selected = selectedMode == LibraryViewMode.Saved,
            onClick = { onModeSelected(LibraryViewMode.Saved) },
        )
        LibraryChip(
            label = stringResource(Res.string.compose_settings_root_downloads_title),
            selected = selectedMode == LibraryViewMode.Downloads,
            onClick = { onModeSelected(LibraryViewMode.Downloads) },
        )
        LibraryChip(
            label = stringResource(Res.string.library_source_cloud),
            selected = selectedMode == LibraryViewMode.Cloud,
            onClick = { onModeSelected(LibraryViewMode.Cloud) },
        )
    }
}

@Composable
private fun CloudLibraryToolbar(
    uiState: CloudLibraryUiState,
    selectedProviderId: String?,
    selectedType: CloudLibraryItemType?,
    availableTypes: List<CloudLibraryItemType>,
    onProviderSelected: (String?) -> Unit,
    onTypeSelected: (CloudLibraryItemType?) -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val providerOptions = buildList {
        add(NuvioDropdownOption(key = "", label = stringResource(Res.string.cloud_library_provider_all)))
        addAll(
            uiState.providers.map { provider ->
                NuvioDropdownOption(
                    key = provider.providerId,
                    label = provider.providerName,
                )
            },
        )
    }
    val typeOptions = buildList {
        add(NuvioDropdownOption(key = "", label = stringResource(Res.string.cloud_library_type_all)))
        addAll(
            availableTypes.map { type ->
                NuvioDropdownOption(
                    key = type.name,
                    label = cloudLibraryTypeLabel(type),
                )
            },
        )
    }
    val selectedProviderName = uiState.providers
        .firstOrNull { provider -> provider.providerId == selectedProviderId }
        ?.providerName
        ?: stringResource(Res.string.cloud_library_provider_all)
    val selectedTypeLabel = selectedType?.let { type -> cloudLibraryTypeLabel(type) }
        ?: stringResource(Res.string.cloud_library_type_all)

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                NuvioDropdownChip(
                    title = stringResource(Res.string.cloud_library_select_provider),
                    label = selectedProviderName,
                    selectedKey = selectedProviderId.orEmpty(),
                    options = providerOptions,
                    enabled = providerOptions.size > 1,
                    onSelected = { option ->
                        onProviderSelected(option.key.ifBlank { null })
                    },
                )
                NuvioDropdownChip(
                    title = stringResource(Res.string.cloud_library_select_type),
                    label = selectedTypeLabel,
                    selectedKey = selectedType?.name.orEmpty(),
                    options = typeOptions,
                    enabled = typeOptions.size > 1,
                    onSelected = { option ->
                        val type = option.key
                            .takeIf { it.isNotBlank() }
                            ?.let(CloudLibraryItemType::valueOf)
                        onTypeSelected(type)
                    },
                )
            }
            IconButton(onClick = onRefresh) {
                Icon(
                    imageVector = Icons.Rounded.Refresh,
                    contentDescription = stringResource(Res.string.cloud_library_refresh),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun LibraryChip(
    label: String,
    selected: Boolean,
    loading: Boolean = false,
    error: Boolean = false,
    onClick: () -> Unit,
) {
    val colorScheme = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
        color = if (selected) colorScheme.primaryContainer else colorScheme.surfaceContainerLow,
        border = if (selected) BorderStroke(1.dp, colorScheme.primary.copy(alpha = 0.45f)) else null,
    ) {
        Text(
            text = label,
            modifier = Modifier
                .padding(horizontal = 14.dp, vertical = 8.dp)
                .shimmer(loading),
            style = MaterialTheme.typography.labelMedium,
            color = when {
                error -> colorScheme.error
                selected -> colorScheme.onPrimaryContainer
                else -> colorScheme.onSurfaceVariant
            },
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CloudLibraryRow(
    item: CloudLibraryItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val playableCount = item.playableFiles.size
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .clickable(enabled = playableCount > 0, onClick = onClick),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = item.name,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = cloudLibrarySubtitle(item),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = cloudLibraryStatusLine(item),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (playableCount > 0) {
                    IconButton(onClick = onClick) {
                        Icon(
                            imageVector = Icons.Rounded.PlayArrow,
                            contentDescription = stringResource(Res.string.action_play),
                        )
                    }
                }
            }
            item.progressFraction?.takeIf { it in 0f..0.999f }?.let { progress ->
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.primary,
                    trackColor = MaterialTheme.colorScheme.surfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun CloudLibraryFilePicker(
    item: CloudLibraryItem,
    onBack: () -> Unit,
    onFileSelected: (CloudLibraryFile) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                        contentDescription = stringResource(Res.string.action_back),
                    )
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = item.name,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = stringResource(Res.string.cloud_library_file_picker_title),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            val files = item.playableFiles
            if (files.isEmpty()) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = stringResource(Res.string.cloud_library_no_files_title),
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = stringResource(Res.string.cloud_library_no_files_message),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                files.forEach { file ->
                    CloudLibraryFileRow(
                        file = file,
                        onClick = { onFileSelected(file) },
                    )
                }
            }
        }
    }
}

@Composable
private fun CloudLibraryFileRow(
    file: CloudLibraryFile,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.58f),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    modifier = Modifier
                        .padding(top = 2.dp)
                        .size(18.dp),
                    imageVector = Icons.AutoMirrored.Filled.InsertDriveFile,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    modifier = Modifier.weight(1f),
                    text = file.name,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = file.sizeBytes?.let { size -> formatCloudBytes(size) }.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    imageVector = Icons.Rounded.PlayArrow,
                    contentDescription = stringResource(Res.string.cloud_library_play_file),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

@Composable
private fun cloudLibrarySubtitle(item: CloudLibraryItem): String {
    val fileLine = when (val playableCount = item.playableFiles.size) {
        0 -> stringResource(Res.string.cloud_library_no_playable_files)
        1 -> item.playableFiles.first().name
        else -> stringResource(Res.string.cloud_library_playable_file_count, playableCount)
    }
    return listOf(item.providerName, cloudLibraryTypeLabel(item.type), fileLine).joinToString(" • ")
}

@Composable
private fun cloudLibraryStatusLine(item: CloudLibraryItem): String {
    val fallback = if (item.playableFiles.isEmpty()) {
        stringResource(Res.string.cloud_library_no_playable_files)
    } else {
        stringResource(Res.string.cloud_library_status_ready)
    }
    return listOfNotNull(
        item.status?.toDisplayStatus(),
        item.sizeBytes?.let(::formatCloudBytes),
        item.progressFraction?.let { "${(it * 100f).toInt()}%" },
    ).joinToString(" • ").ifBlank { fallback }
}

@Composable
private fun cloudLibraryTypeLabel(type: CloudLibraryItemType): String =
    when (type) {
        CloudLibraryItemType.Torrent -> stringResource(Res.string.cloud_library_type_torrents)
        CloudLibraryItemType.Usenet -> stringResource(Res.string.cloud_library_type_usenet)
        CloudLibraryItemType.WebDownload -> stringResource(Res.string.cloud_library_type_web)
        CloudLibraryItemType.File -> stringResource(Res.string.cloud_library_type_files)
    }

private fun formatCloudBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 ${localizedByteUnit("B")}"
    val kib = 1024.0
    val mib = kib * 1024.0
    val gib = mib * 1024.0
    val value = bytes.toDouble()
    return when {
        value >= gib -> "${((value / gib) * 10.0).toInt() / 10.0} ${localizedByteUnit("GB")}"
        value >= mib -> "${((value / mib) * 10.0).toInt() / 10.0} ${localizedByteUnit("MB")}"
        value >= kib -> "${((value / kib) * 10.0).toInt() / 10.0} ${localizedByteUnit("KB")}"
        else -> "$bytes ${localizedByteUnit("B")}"
    }
}

private fun String.toDisplayStatus(): String =
    replace('_', ' ')
        .lowercase()
        .replaceFirstChar { it.titlecase() }

@Composable
private fun CloudLibrarySkeletonToolbar(
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SkeletonBlock(width = 112.dp, height = 36.dp, cornerRadius = 12.dp)
            SkeletonBlock(width = 92.dp, height = 36.dp, cornerRadius = 12.dp)
        }
    }
}

@Composable
private fun CloudLibrarySkeletonRow(
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    SkeletonBlock(
                        modifier = Modifier.fillMaxWidth(0.74f),
                        height = 18.dp,
                        cornerRadius = 6.dp,
                    )
                    SkeletonBlock(
                        modifier = Modifier.fillMaxWidth(0.9f),
                        height = 14.dp,
                        cornerRadius = 6.dp,
                    )
                    SkeletonBlock(
                        modifier = Modifier.fillMaxWidth(0.52f),
                        height = 12.dp,
                        cornerRadius = 6.dp,
                    )
                }
                SkeletonBlock(width = 48.dp, height = 48.dp, cornerRadius = 24.dp)
            }
        }
    }
}

private enum class LibraryViewMode {
    Saved,
    Downloads,
    Cloud,
}

private fun LazyListScope.librarySections(
    displaySections: List<LibraryDisplaySection>,
    watchedKeys: Set<String>,
    fullyWatchedSeriesKeys: Set<String>,
    sortOption: LibrarySortOption,
    onPosterClick: ((LibraryItem) -> Unit)?,
    onSectionViewAllClick: ((LibrarySection, LibrarySortOption) -> Unit)?,
    onPosterLongClick: ((LibraryItem, LibrarySection) -> Unit)?,
    onDisintegrated: (String) -> Unit,
) {
    items(
        items = displaySections,
        key = { section -> "library-horizontal:${section.type}" },
    ) { section ->
        NuvioShelfSection(
            title = section.displayTitle,
            entries = section.previewEntries,
            modifier = libraryContentTransitionModifier(),
            headerHorizontalPadding = 16.dp,
            rowContentPadding = PaddingValues(horizontal = 16.dp),
            onViewAllClick = section.source
                ?.takeIf { it.items.size > LIBRARY_SECTION_PREVIEW_LIMIT }
                ?.let { source -> onSectionViewAllClick?.let { { it(source, sortOption) } } },
            viewAllPillSize = NuvioViewAllPillSize.Compact,
            key = { entry -> entry.globalKey },
            animatePlacement = true,
        ) { entry ->
            val item = entry.item
            val posterItem = item.toMetaPreview()
            val entrySource = entry.section
            DisintegratingContainer(
                disintegrating = entry.exiting,
                onDisintegrated = { onDisintegrated(entry.globalKey) },
            ) {
                HomePosterCard(
                    item = posterItem,
                    isWatched = WatchingState.isPosterWatched(
                        watchedKeys = watchedKeys,
                        item = posterItem,
                        fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                    ),
                    onClick = if (entry.exiting) null else onPosterClick?.let { { it(item) } },
                    onLongClick = if (entry.exiting || entrySource == null) {
                        null
                    } else {
                        onPosterLongClick?.let { { it(item, entrySource) } }
                    },
                )
            }
        }
    }
}

private const val LIBRARY_SECTION_PREVIEW_LIMIT = 18

private data class LibraryDisplayEntry(
    val globalKey: String,
    val item: LibraryItem,
    val section: LibrarySection?,
    val exiting: Boolean,
)

private data class LibraryDisplaySection(
    val source: LibrarySection?,
    val type: String,
    val displayTitle: String,
    val previewEntries: List<LibraryDisplayEntry>,
)

private class LibraryExitingEntry(
    val item: LibraryItem,
    val sectionType: String,
    val sectionTitle: String,
    val index: Int,
)

private class LibraryDisintegrationHolder {
    private val tracker = ScopedDisintegrationTracker<LibrarySourceMode, String, LibraryExitingEntry> { entry ->
        librarySectionItemKey(entry.sectionType, entry.item)
    }

    fun onExited(globalKey: String) {
        tracker.onDisintegrated(globalKey)
    }

    fun reset() {
        tracker.reset()
    }

    fun sync(
        sourceMode: LibrarySourceMode,
        sections: List<LibrarySection>,
        previewLimit: Int,
        request: DisintegrationRequest<String>?,
    ): List<LibraryDisplaySection> {
        val current = ArrayList<LibraryExitingEntry>()
        sections.forEach { section ->
            section.items.take(previewLimit).forEachIndexed { index, item ->
                current += LibraryExitingEntry(item, section.type, section.displayTitle, index)
            }
        }
        val exitingBySection = tracker.sync(sourceMode, current, request)
            .asSequence()
            .filter { entry -> entry.exiting }
            .map { entry -> entry.item }
            .groupBy { entry -> entry.sectionType }
        val seenTypes = HashSet<String>(sections.size)
        val result = ArrayList<LibraryDisplaySection>(sections.size + 1)

        for (section in sections) {
            seenTypes += section.type
            val entries = ArrayList<LibraryDisplayEntry>(previewLimit + 1)
            section.items.take(previewLimit).forEach { item ->
                entries += LibraryDisplayEntry(
                    globalKey = librarySectionItemKey(section.type, item),
                    item = item,
                    section = section,
                    exiting = false,
                )
            }
            exitingBySection[section.type]?.sortedBy { it.index }?.forEach { ex ->
                val key = librarySectionItemKey(section.type, ex.item)
                if (entries.none { it.globalKey == key }) {
                    entries.add(
                        ex.index.coerceIn(0, entries.size),
                        LibraryDisplayEntry(key, ex.item, section, exiting = true),
                    )
                }
            }
            result += LibraryDisplaySection(section, section.type, section.displayTitle, entries)
        }

        for ((type, list) in exitingBySection) {
            if (type in seenTypes) continue
            val sorted = list.sortedBy { it.index }
            val entries = sorted.map { ex ->
                LibraryDisplayEntry(librarySectionItemKey(type, ex.item), ex.item, section = null, exiting = true)
            }
            result += LibraryDisplaySection(null, type, sorted.first().sectionTitle, entries)
        }

        return result
    }
}

private const val LIBRARY_DOWNLOADS_PREVIEW_LIMIT = 50

private fun LazyListScope.downloadsLibraryContent(
    uiState: DownloadsUiState,
    selectedFilter: LibraryDownloadsFilter,
    selectedGenre: String?,
    onFilterSelected: (LibraryDownloadsFilter) -> Unit,
    onGenreSelected: (String?) -> Unit,
    onPosterClick: ((LibraryItem) -> Unit)?,
    onOpenDownload: ((DownloadItem) -> Unit)?,
    onDownloadLongClick: (LibraryDownloadActionTarget) -> Unit,
) {
    val activeItems = uiState.activeItems.sortedByDescending { it.updatedAtEpochMs }
    val completedMovies = uiState.completedItems
        .filterNot(DownloadItem::isEpisode)
        .sortedByDescending { it.updatedAtEpochMs }
    val completedShows = uiState.completedItems
        .filter(DownloadItem::isEpisode)
        .groupBy { it.parentMetaId }
        .mapNotNull { (_, episodes) ->
            episodes.sortedForSeriesDownloads().lastOrNull()?.let { latest ->
                LibraryDownloadShowGroup(latest, episodes)
            }
        }
        .sortedBy { it.representative.title.lowercase() }
    val movieEntries = completedMovies.map { LibraryDownloadDisplayEntry.Movie(it) }
    val showEntries = completedShows.map { LibraryDownloadDisplayEntry.Show(it) }
    val allEntries = (movieEntries + showEntries)
        .sortedByDescending { it.sortEpochMs }
    val availableGenres = when (selectedFilter) {
        LibraryDownloadsFilter.All -> emptyList()
        LibraryDownloadsFilter.Movies -> movieEntries.flatMap { it.genres }.normalizedDownloadGenres()
        LibraryDownloadsFilter.Shows -> showEntries.flatMap { it.genres }.normalizedDownloadGenres()
    }
    val effectiveSelectedGenre = selectedGenre
        ?.takeIf { selected ->
            availableGenres.any { genre -> genre.equals(selected, ignoreCase = true) }
        }
    val visibleEntries = when (selectedFilter) {
        LibraryDownloadsFilter.All -> allEntries
        LibraryDownloadsFilter.Movies -> movieEntries
        LibraryDownloadsFilter.Shows -> showEntries
    }
        .filter { entry ->
            effectiveSelectedGenre == null ||
                entry.genres.any { genre -> genre.equals(effectiveSelectedGenre, ignoreCase = true) }
        }
        .sortedByDescending { it.sortEpochMs }

    if (uiState.items.isEmpty()) {
        item(key = "library-downloads-empty") {
            LibraryDownloadsEmptyState(
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 30.dp),
            )
        }
        return
    }

    if (activeItems.isNotEmpty()) {
        item(key = "library-downloads-active") {
            NuvioShelfSection(
                title = stringResource(Res.string.downloads_section_downloading),
                entries = activeItems.take(LIBRARY_DOWNLOADS_PREVIEW_LIMIT),
                headerHorizontalPadding = 16.dp,
                rowContentPadding = PaddingValues(horizontal = 16.dp),
                onViewAllClick = null,
                viewAllPillSize = NuvioViewAllPillSize.Compact,
                key = { item -> item.id },
            ) { item ->
                val target = LibraryDownloadActionTarget(
                    entryKey = "active-${item.id}",
                    primaryDownload = item,
                    downloads = listOf(item),
                    libraryItem = item.toDownloadedLibraryItem(),
                )
                LibraryActiveDownloadCard(
                    item = item,
                    onClick = {
                        if (item.isPlayable) {
                            onOpenDownload?.invoke(item)
                        } else {
                            onDownloadLongClick(target)
                        }
                    },
                    onLongClick = { onDownloadLongClick(target) },
                )
            }
        }
    }

    item(key = "library-downloads-filters") {
        LibraryDownloadsFilterRow(
            selectedFilter = selectedFilter,
            allCount = allEntries.size,
            movieCount = movieEntries.size,
            showCount = showEntries.size,
            onFilterSelected = onFilterSelected,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
        )
    }

    if (availableGenres.isNotEmpty()) {
        item(key = "library-downloads-genres-${selectedFilter.name}") {
            LibraryDownloadsGenreRow(
                genres = availableGenres,
                selectedGenre = effectiveSelectedGenre,
                onGenreSelected = onGenreSelected,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
            )
        }
    }

    if (visibleEntries.isNotEmpty()) {
        item(key = "library-downloads-${selectedFilter.name}-${effectiveSelectedGenre.orEmpty()}") {
            NuvioShelfSection(
                title = when (selectedFilter) {
                    LibraryDownloadsFilter.All -> stringResource(Res.string.downloads_section_all)
                    LibraryDownloadsFilter.Movies -> stringResource(Res.string.downloads_section_movies)
                    LibraryDownloadsFilter.Shows -> stringResource(Res.string.downloads_section_shows)
                },
                entries = visibleEntries,
                headerHorizontalPadding = 16.dp,
                rowContentPadding = PaddingValues(horizontal = 16.dp),
                onViewAllClick = null,
                viewAllPillSize = NuvioViewAllPillSize.Compact,
                key = { entry -> entry.key },
            ) { entry ->
                val representative = entry.representative
                val libraryItem = when (entry) {
                    is LibraryDownloadDisplayEntry.Movie -> representative.toDownloadedLibraryItem()
                    is LibraryDownloadDisplayEntry.Show -> representative
                        .toDownloadedLibraryItem()
                        .copy(releaseInfo = stringResource(Res.string.downloads_episode_count, entry.group.episodes.size))
                }
                val target = LibraryDownloadActionTarget(
                    entryKey = entry.key,
                    primaryDownload = representative,
                    downloads = when (entry) {
                        is LibraryDownloadDisplayEntry.Movie -> listOf(representative)
                        is LibraryDownloadDisplayEntry.Show -> entry.group.episodes
                    },
                    libraryItem = libraryItem,
                )
                HomePosterCard(
                    item = libraryItem.toMetaPreview(),
                    isWatched = false,
                    onClick = {
                        if (onPosterClick != null) {
                            onPosterClick(libraryItem)
                        } else {
                            onOpenDownload?.invoke(representative)
                        }
                    },
                    onLongClick = { onDownloadLongClick(target) },
                )
            }
        }
    } else if (allEntries.isNotEmpty()) {
        item(key = "library-downloads-filter-empty") {
            Text(
                text = stringResource(Res.string.downloads_filter_empty),
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun LibraryDownloadsEmptyState(
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .height(430.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        LibraryDownloadsEmptyArtwork()
        Spacer(modifier = Modifier.height(34.dp))
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = stringResource(Res.string.downloads_empty_title),
                modifier = Modifier.widthIn(max = 430.dp),
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(Res.string.downloads_empty_message),
                modifier = Modifier.widthIn(max = 430.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun LibraryDownloadsEmptyArtwork(
    modifier: Modifier = Modifier,
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    Box(
        modifier = modifier.size(width = 210.dp, height = 158.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.matchParentSize()) {
            drawCircle(
                brush = Brush.radialGradient(
                    0f to primaryColor.copy(alpha = 0.22f),
                    1f to Color.Transparent,
                    center = center,
                    radius = size.minDimension * 0.62f,
                ),
                radius = size.minDimension * 0.62f,
                center = center,
            )
        }
        LibraryDownloadsArtworkCard(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = 18.dp)
                .rotate(-10f),
            alpha = 0.56f,
        )
        LibraryDownloadsArtworkCard(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 18.dp)
                .rotate(10f),
            alpha = 0.56f,
        )
        Surface(
            modifier = Modifier.size(width = 116.dp, height = 144.dp),
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f),
            border = BorderStroke(2.dp, MaterialTheme.colorScheme.primary),
            shadowElevation = 10.dp,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Rounded.Download,
                    contentDescription = null,
                    modifier = Modifier.size(38.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

@Composable
private fun LibraryDownloadsArtworkCard(
    modifier: Modifier = Modifier,
    alpha: Float,
) {
    Surface(
        modifier = modifier.size(width = 112.dp, height = 138.dp),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow.copy(alpha = alpha),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.22f)),
    ) {}
}

@Composable
private fun LibraryDownloadsFilterRow(
    selectedFilter: LibraryDownloadsFilter,
    allCount: Int,
    movieCount: Int,
    showCount: Int,
    onFilterSelected: (LibraryDownloadsFilter) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LibraryDownloadFilterChip(
            label = stringResource(Res.string.downloads_filter_all),
            value = allCount.toString(),
            selected = selectedFilter == LibraryDownloadsFilter.All,
            onClick = { onFilterSelected(LibraryDownloadsFilter.All) },
        )
        LibraryDownloadFilterChip(
            label = stringResource(Res.string.downloads_section_movies),
            value = movieCount.toString(),
            selected = selectedFilter == LibraryDownloadsFilter.Movies,
            onClick = { onFilterSelected(LibraryDownloadsFilter.Movies) },
        )
        LibraryDownloadFilterChip(
            label = stringResource(Res.string.downloads_section_shows),
            value = showCount.toString(),
            selected = selectedFilter == LibraryDownloadsFilter.Shows,
            onClick = { onFilterSelected(LibraryDownloadsFilter.Shows) },
        )
    }
}

@Composable
private fun LibraryDownloadsGenreRow(
    genres: List<String>,
    selectedGenre: String?,
    onGenreSelected: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LibraryDownloadFilterChip(
            label = stringResource(Res.string.downloads_filter_all),
            selected = selectedGenre == null,
            onClick = { onGenreSelected(null) },
        )
        genres.forEach { genre ->
            LibraryDownloadFilterChip(
                label = genre,
                selected = selectedGenre.equals(genre, ignoreCase = true),
                onClick = { onGenreSelected(genre) },
            )
        }
    }
}

@Composable
private fun LibraryDownloadFilterChip(
    label: String,
    value: String? = null,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(18.dp)
    Surface(
        modifier = modifier
            .clip(shape)
            .clickable(onClick = onClick),
        shape = shape,
        color = if (selected) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
        } else {
            MaterialTheme.colorScheme.surfaceContainerLow.copy(alpha = 0.74f)
        },
        border = BorderStroke(
            1.dp,
            if (selected) {
                MaterialTheme.colorScheme.primary.copy(alpha = 0.88f)
            } else {
                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.28f)
            },
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            if (value != null) {
                Text(
                    text = value,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Bold,
                )
            }
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = if (selected) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun LibraryActiveDownloadCard(
    item: DownloadItem,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val posterCardStyle by remember {
        PosterCardStyleRepository.ensureLoaded()
        PosterCardStyleRepository.uiState
    }.collectAsStateWithLifecycle()
    val cardShape = RoundedCornerShape(posterCardStyle.cornerRadiusDp.dp)
    val artwork = item.poster?.takeIf { it.isNotBlank() }
        ?: item.episodeThumbnail?.takeIf { it.isNotBlank() }
        ?: item.background?.takeIf { it.isNotBlank() }
    val progress = item.progressFraction.coerceIn(0f, 1f)
    val progressPercent = (progress * 100f).toInt().coerceIn(0, 100)
    val progressInfoLines = item.downloadProgressInfoLines()

    Column(
        modifier = modifier.width(posterCardStyle.widthDp.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(0.675f)
                .clip(cardShape)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .posterCardClickable(
                    onClick = onClick,
                    onLongClick = onLongClick,
                    zoomImageUrl = artwork,
                    zoomCornerRadius = posterCardStyle.cornerRadiusDp.dp,
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (!artwork.isNullOrBlank()) {
                AsyncImage(
                    model = artwork,
                    contentDescription = item.downloadDisplayTitle(),
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                Text(
                    text = item.downloadDisplayTitle().take(1).uppercase(),
                    style = MaterialTheme.typography.headlineMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                )
            }
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.58f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.68f),
                        ),
                    ),
            )
            Surface(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(9.dp),
                shape = RoundedCornerShape(999.dp),
                color = Color.Black.copy(alpha = 0.58f),
                contentColor = Color.White,
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.12f)),
            ) {
                Text(
                    text = "$progressPercent%",
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
        }

        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(999.dp)),
            color = MaterialTheme.colorScheme.primary,
            trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
        )

        if (!posterCardStyle.hideLabelsEnabled) {
            Column(
                modifier = Modifier.padding(horizontal = 2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = item.downloadDisplayTitle(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = item.downloadSubtitle(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                progressInfoLines.forEach { line ->
                    Text(
                        text = line,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.88f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

private data class LibraryDownloadShowGroup(
    val representative: DownloadItem,
    val episodes: List<DownloadItem>,
)

data class LibraryDownloadActionTarget(
    val entryKey: String,
    val primaryDownload: DownloadItem,
    val downloads: List<DownloadItem>,
    val libraryItem: LibraryItem,
)

private sealed class LibraryDownloadDisplayEntry {
    abstract val key: String
    abstract val representative: DownloadItem
    abstract val sortEpochMs: Long
    abstract val genres: List<String>

    data class Movie(
        val download: DownloadItem,
    ) : LibraryDownloadDisplayEntry() {
        override val key: String = "movie-${download.id}"
        override val representative: DownloadItem = download
        override val sortEpochMs: Long = download.updatedAtEpochMs
        override val genres: List<String> = emptyList()
    }

    data class Show(
        val group: LibraryDownloadShowGroup,
    ) : LibraryDownloadDisplayEntry() {
        override val key: String = "show-${group.representative.parentMetaId}"
        override val representative: DownloadItem = group.representative
        override val sortEpochMs: Long = group.episodes.maxOfOrNull { it.updatedAtEpochMs }
            ?: group.representative.updatedAtEpochMs
        override val genres: List<String> = emptyList()
    }
}

private enum class LibraryDownloadsFilter {
    All,
    Movies,
    Shows,
}

private fun List<String>.normalizedDownloadGenres(): List<String> =
    map { it.trim() }
        .filter { it.isNotBlank() }
        .distinctBy { it.lowercase() }
        .sortedBy { it.lowercase() }

private fun DownloadItem.downloadDisplayTitle(): String =
    if (isEpisode) {
        episodeTitle?.trim()?.takeIf { it.isNotBlank() } ?: title
    } else {
        title
    }

private fun DownloadItem.downloadSubtitle(): String =
    listOfNotNull(
        title.takeIf { isEpisode && it.isNotBlank() && it != downloadDisplayTitle() },
        streamTitle.takeIf { it.isNotBlank() && it != downloadDisplayTitle() },
    ).joinToString(" • ").ifBlank { providerName }

private fun DownloadItem.downloadProgressInfoLines(): List<String> {
    val sizeText = if (totalBytes != null && totalBytes > 0L) {
        "${formatDownloadBytes(downloadedBytes)} / ${formatDownloadBytes(totalBytes)}"
    } else {
        formatDownloadBytes(downloadedBytes)
    }
    val statusText = when (status) {
        DownloadStatus.Downloading -> "Downloading"
        DownloadStatus.Paused -> "Paused"
        DownloadStatus.Completed -> "Completed"
        DownloadStatus.Failed -> errorMessage ?: "Failed"
    }
    return listOf(sizeText, statusText)
}

private fun formatDownloadBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 ${localizedByteUnit("B")}"
    val kib = 1024.0
    val mib = kib * 1024.0
    val gib = mib * 1024.0
    val value = bytes.toDouble()
    return when {
        value >= gib -> "${((value / gib) * 10.0).toInt() / 10.0} ${localizedByteUnit("GB")}"
        value >= mib -> "${((value / mib) * 10.0).toInt() / 10.0} ${localizedByteUnit("MB")}"
        value >= kib -> "${((value / kib) * 10.0).toInt() / 10.0} ${localizedByteUnit("KB")}"
        else -> "$bytes ${localizedByteUnit("B")}"
    }
}

private fun DownloadItem.toDownloadedLibraryItem(): LibraryItem {
    val type = parentMetaType.trim().ifBlank { contentType.trim() }.ifBlank { "movie" }
    val posterImage = poster?.takeIf { it.isNotBlank() }
        ?: episodeThumbnail?.takeIf { it.isNotBlank() }
        ?: background?.takeIf { it.isNotBlank() }
    val releaseInfo = if (isEpisode) {
        val s = seasonNumber ?: 1
        val ep = episodeNumber ?: 1
        "S${s} E${ep}"
    } else null

    return LibraryItem(
        id = parentMetaId.trim().ifBlank { id },
        type = type,
        name = title.trim().ifBlank { streamTitle },
        poster = posterImage,
        banner = background?.takeIf { it.isNotBlank() },
        logo = logo?.takeIf { it.isNotBlank() },
        description = episodeTitle?.takeIf { it.isNotBlank() },
        releaseInfo = releaseInfo,
        imdbRating = null,
        genres = emptyList(),
        savedAtEpochMs = updatedAtEpochMs.takeIf { it > 0L } ?: createdAtEpochMs,
    )
}

