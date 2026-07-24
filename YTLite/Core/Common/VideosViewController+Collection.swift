import UIKit

/// A titled group of videos rendered as one collection-view section.
struct VideoSection {
    let title: String?
    var videos: [Video]
    /// The shelf's own token — rails page horizontally with it.
    var continuation: String?
}

// MARK: - Section Accessors

extension VideosViewController {
    func video(at indexPath: IndexPath) -> Video {
        sections[indexPath.section].videos[indexPath.item]
    }

    /// Number of videos after the given index path (for the
    /// load-more trigger).
    func videosRemaining(after indexPath: IndexPath) -> Int {
        var remaining = sections[indexPath.section].videos.count
            - indexPath.item - 1
        for section in sections.dropFirst(indexPath.section + 1) {
            remaining += section.videos.count
        }
        return remaining
    }

    func openChannel(for video: Video) {
        guard let channelId = video.channelId else {
            return
        }
        navigationController?.pushViewController(
            channelViewControllerFactory(
                channelId,
                video.channelName
            ),
            animated: true
        )
    }

    func endRefreshing() {
        collectionView?.refreshControl?.endRefreshing()
    }

    func updateItemSize() {
        guard let collectionView,
              let layout = collectionView
                  .collectionViewLayout
                  as? UICollectionViewFlowLayout
        else {
            return
        }
        let inset = layout.sectionInset.left
            + layout.sectionInset.right
        let spacing = layout.minimumInteritemSpacing
            * CGFloat(max(columns - 1, 0))
        let available = collectionView.bounds.width
            - inset - spacing
        let width = floor(available / CGFloat(columns))
        let height: CGFloat = width * (9.0 / 16.0) + 92
        let newSize = CGSize(
            width: width,
            height: height
        )
        if layout.itemSize != newSize {
            layout.itemSize = newSize
            layout.invalidateLayout()
        }
    }
}

// MARK: - UICollectionViewDataSource

extension VideosViewController: UICollectionViewDataSource {
    func numberOfSections(
        in collectionView: UICollectionView
    ) -> Int {
        isLoadingInitial ? 1 : sections.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        if isLoadingInitial {
            return VideosViewController.skeletonCount
        }
        return useRails ? 1 : sections[section].videos.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if !isLoadingInitial, useRails {
            return railCell(in: collectionView, at: indexPath)
        }
        guard let cell = collectionView
            .dequeueReusableCell(
                withReuseIdentifier: VideoCell.reuseId,
                for: indexPath
            ) as? VideoCell
        else {
            return UICollectionViewCell()
        }
        cell.forceGridLayout = true
        if isLoadingInitial {
            cell.configureSkeleton()
            return cell
        }
        let video = video(at: indexPath)
        cell.configure(with: video)
        cell.onChannelTap = { [weak self] in
            self?.openChannel(for: video)
        }
        return cell
    }

    private func railCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ShelfRailCell.reuseId,
            for: indexPath
        ) as? ShelfRailCell else {
            return UICollectionViewCell()
        }
        let section = indexPath.section
        cell.configure(with: sections[section].videos)
        cell.onVideoTap = { [weak self] video in
            self?.openVideo(video)
        }
        cell.onChannelTap = { [weak self] video in
            self?.openChannel(for: video)
        }
        cell.onNearEnd = { [weak self] in
            self?.loadMoreInRail(section: section)
        }
        return cell
    }

    /// Horizontal pagination: extends the rail with its shelf's next
    /// page when the user scrolls near its trailing edge.
    private func loadMoreInRail(section: Int) {
        guard section < sections.count,
              let token = sections[section].continuation,
              !loadingRailSections.contains(section)
        else {
            return
        }
        loadingRailSections.insert(section)
        loadRailPage(token: token) { [weak self] page in
            self?.finishRailLoad(section: section, page: page)
        }
    }

    private func finishRailLoad(section: Int, page: FeedPage?) {
        loadingRailSections.remove(section)
        guard let page, section < sections.count else {
            return
        }
        let added = appendToRail(
            page.videos,
            section: section,
            continuation: page.continuation
        )
        guard !added.isEmpty else {
            return
        }
        let cell = collectionView?.cellForItem(
            at: IndexPath(item: 0, section: section)
        ) as? ShelfRailCell
        cell?.appendVideos(added)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                  ofKind: kind,
                  withReuseIdentifier: VideoSectionHeaderView.reuseId,
                  for: indexPath
              ) as? VideoSectionHeaderView
        else {
            return UICollectionReusableView()
        }
        let title = isLoadingInitial
            ? nil : sections[indexPath.section].title
        header.configure(title: title)
        return header
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension VideosViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial else {
            return
        }
        openVideo(video(at: indexPath))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial,
              !isLoadingMore,
              currentContinuation != nil,
              nearFeedEnd(indexPath)
        else {
            return
        }
        isLoadingMore = true
        handleLoadMore()
    }

    private func nearFeedEnd(_ indexPath: IndexPath) -> Bool {
        useRails
            ? indexPath.section >= sections.count - 3
            : videosRemaining(after: indexPath) < 4
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let flow = collectionViewLayout
            as? UICollectionViewFlowLayout
        guard useRails, !isLoadingInitial else {
            return flow?.itemSize ?? .zero
        }
        // Full width minus the section's horizontal insets.
        return CGSize(
            width: collectionView.bounds.width - 16,
            height: ShelfRailCell.railHeight
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard !isLoadingInitial,
              section < sections.count,
              sections[section].title != nil
        else {
            return .zero
        }
        return CGSize(
            width: collectionView.bounds.width,
            height: VideoSectionHeaderView.height
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        // The default per-section inset would double the vertical gap
        // between stacked sections — only the first keeps a top inset.
        UIEdgeInsets(
            top: section == 0 ? 12 : 0,
            left: 8,
            bottom: 12,
            right: 8
        )
    }

    func scrollViewDidScroll(
        _ scrollView: UIScrollView
    ) {
        guard scrollView === collectionView else {
            return
        }
        topBarHider.handleScroll(scrollView)
        handleScroll(scrollView)
    }
}
