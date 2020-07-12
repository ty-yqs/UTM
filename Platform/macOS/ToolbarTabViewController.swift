//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI

public struct ToolbarTabViewController: NSViewControllerRepresentable {
    let tabViewItems: [NSTabViewItem]
    
    public init(tabViewItems: [NSTabViewItem]) {
        self.tabViewItems = tabViewItems
    }
    
    public func makeNSViewController(context: Context) -> UTMTabViewController {
        let tab = UTMTabViewController()
        tab.tabStyle = .toolbar
        tab.tabViewItems = tabViewItems
        return tab
    }
    
    public func updateNSViewController(_ controller: UTMTabViewController, context: Context) {
        
    }
}
