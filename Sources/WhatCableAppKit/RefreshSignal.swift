import Combine

public final class RefreshSignal: ObservableObject {
    @Published public var tick: Int = 0
    @Published public var optionHeld: Bool = false
    @Published public var showSettings: Bool = false

    public init() {}

    public func bump() { tick &+= 1 }
}
