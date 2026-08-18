@_spi(Rendering) import EngageMessageCenter

func shouldInvalidateMessageCenterDetail(
    entryId: InboxEntryId,
    expectedLifecycleRevision: Int64,
    state: MessageCenterPresentationState,
    knownByInbox: Bool,
    rendered: Bool
) -> Bool {
    state.lifecycleRevision != expectedLifecycleRevision
        || state.deletedEntryIds.contains(entryId)
        || knownByInbox && !state.entryIds.contains(entryId)
        || rendered && !state.isEnabled
}

func isMessageCenterContentVisible(visibleArea: Double, totalArea: Double) -> Bool {
    totalArea > 0 && visibleArea / totalArea >= 0.5
}

func shouldApplyMessageCenterNativeChrome(hasPublishedRendering: Bool) -> Bool {
    !hasPublishedRendering
}
