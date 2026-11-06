import SwiftUI
// Keep the property-wrapper API available with Command Line Tools, which does
// not ship the newer SDK's SwiftUI macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
