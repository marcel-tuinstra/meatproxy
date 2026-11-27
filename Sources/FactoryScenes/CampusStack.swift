import SpriteKit
import FactoryCore

/// 4A (D65): a tower apart. Its picture is cut along the storeys' edges into the plinth, one piece per storey and the
/// roof. Only the storey under the pointer comes loose (D73): it lifts a little, everything above it lifts a whole gap,
/// and the gap shows a thin cut through that one storey (desks, people, screens). Together (e = 0) the tower is its
/// own sprite again, pixel for pixel.
final class TowerStack {
    let key: String
    let root: SKNode
    let texture: SKTexture
    var base: SKNode?
    var pieces: [SKNode] = []          // storey k
    var roof: SKNode?
    var sprites: [SKSpriteNode] = []
    /// per storey: its facade (the cut picture), the room behind it, and how far you see in (0 facade, 1 inside)
    var facades: [SKSpriteNode] = []
    var insides: [SKNode] = []
    var seeIn: [CGFloat] = []
    /// each piece on its own spring (storey k, the roof last), in gaps: 0 together, 0.4 the loose storey, 1.4 above it
    var pos: [CGFloat] = [], vel: [CGFloat] = []
    /// the storey that comes loose: under the pointer, or the wheel's mark
    var hot: Int?
    var since = 0.0
    /// how far apart, 0 to 1
    var e: CGFloat { min(1, (pos.max() ?? 0) / 1.4) }
    static let loose: CGFloat = 0.4, above: CGFloat = 1.4
    var target: CGFloat = 0
    var gap: CGFloat = 19              // art units between storeys when apart
    var wantFor = 0.0, awayFor = 0.0
    init(key: String, root: SKNode, texture: SKTexture) { self.key = key; self.root = root; self.texture = texture }
    /// how far storey k (and the roof, k = count) has lifted, in art units
    func offset(_ k: Int) -> CGFloat {
        guard pos.indices.contains(k) else { return 0 }
        return gap * pos[k]
    }
    var roofOffset: CGFloat { offset(pieces.count) }
}

extension CampusScene {
    /// A clear picture: the tower's own sprite shows nothing while its pieces stand apart.
    static let clearTexture: SKTexture = {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SKTexture(cgImage: ctx.makeImage()!)
    }()

    /// A layer of a building's overlay that moves with one storey (nil: with the roof).
    func layer(_ key: String, storey k: Int?) -> SKNode? {
        guard let ov = overlays[key] else { return nil }
        let name = k.map { "storey-\($0)" } ?? "roof"
        if let n = ov.childNode(withName: name) { return n }
        let n = SKNode(); n.name = name; ov.addChild(n)
        return n
    }

    func isApart(_ key: String) -> Bool { (stacks[key]?.e ?? 0) > 0.35 && stacks[key]?.target == 1 }

    /// Cut each provider tower into its pieces, hidden until it opens.
    func buildStacks(_ world: World) {
        guard let art else { return }
        for key in ["claude", "chatgpt"] {
            guard let b = buildings[key], let tex = b.texture else { continue }
            let sts = art.storeys.filter { $0.building == key }.sorted { $0.index < $1.index }
            guard let top = sts.last, sts.allSatisfy({ $0.faces.count == 2 && $0.faces.allSatisfy { $0.count == 4 } }) else { continue }
            let root = SKNode(); root.position = CGPoint(x: -b.position.x, y: -b.position.y); root.zPosition = 0.1; root.isHidden = true
            b.addChild(root)
            let st = TowerStack(key: key, root: root, texture: tex)
            // the sprite's box in art units, with room to spare
            let fr = b.frame
            let L = fr.minX / px - 10, R = fr.maxX / px + 10, T = -fr.maxY / px - 10, B = -fr.minY / px + 10
            // a cut: a storey's bottom edge (front face, then right face), carried on to the sides along the faces' slope
            func cut(_ a: CGPoint, _ m: CGPoint, _ c: CGPoint) -> [CGPoint] {
                [CGPoint(x: L, y: a.y - (a.x - L) / 2), a, m, c, CGPoint(x: R, y: c.y - (R - c.x) / 2)]
            }
            var cuts = sts.map { cut($0.faces[0][0], $0.faces[0][1], $0.faces[1][1]) }
            // under the roof: its overhang (.15 of a tile) goes with the roof; a proud factory storey is wider than it
            let a3 = top.faces[0][3], a2 = top.faces[0][2], b2 = top.faces[1][2]
            cuts.append(top.kind == "factory" ? cut(a3, a2, b2)
                        : cut(CGPoint(x: a3.x - 4.8, y: a3.y), CGPoint(x: a2.x, y: a2.y + 2.4), CGPoint(x: b2.x + 4.8, y: b2.y)))
            func piece(above: [CGPoint]?, below: [CGPoint]?, z: CGFloat, facade: Bool = false) -> SKNode {
                let up = above ?? [CGPoint(x: L, y: T), CGPoint(x: R, y: T)]
                let lo = below ?? [CGPoint(x: L, y: B), CGPoint(x: R, y: B)]
                let holder = SKNode(); holder.zPosition = z
                let crop = SKCropNode(); crop.maskNode = shape(up + lo.reversed(), fill: .white)
                let s = SKSpriteNode(texture: tex); s.anchorPoint = b.anchorPoint; s.size = b.size; s.position = b.position
                crop.addChild(s); holder.addChild(crop); root.addChild(holder)
                st.sprites.append(s)
                if facade { st.facades.append(s) }
                return holder
            }
            st.base = piece(above: cuts[0], below: nil, z: 0.001)
            for (k, s) in sts.enumerated() {
                let h = piece(above: cuts[k + 1], below: cuts[k], z: 0.002 + 0.002 * CGFloat(k), facade: true)
                let inside = SKNode(); inside.zPosition = -0.0008; inside.alpha = 0; inside.isHidden = true
                if let id = storeys.first(where: { $0.storey.building == key && $0.storey.index == s.index })?.project, let p = world.project(id: id) {
                    let cutaway = floorCut(s, p, world: world); cutaway.zPosition = 0.0005; h.addChild(cutaway)
                    inside.addChild(room(s, p, world: world))
                }
                h.addChild(inside); st.insides.append(inside); st.seeIn.append(0)
                st.pieces.append(h)
            }
            st.roof = piece(above: nil, below: cuts[sts.count], z: 0.002 + 0.002 * CGFloat(sts.count))
            let n = sts.count + 1
            st.pos = Array(repeating: 0, count: n); st.vel = st.pos
            stacks[key] = st
        }
    }

    /// The cut through a storey's ceiling, where it came loose: a plain slab with a light rim.
    func floorCut(_ s: CampusArt.Storey, _ p: Project, world: World) -> SKNode {
        let n = SKNode()
        let A = s.faces[0][3], Bc = s.faces[0][2], C = s.faces[1][2]
        let D = CGPoint(x: A.x + C.x - Bc.x, y: A.y + C.y - Bc.y)
        // a point on the ceiling: u along the front (left to right), v from the front edge back, h up (art units)
        func Q(_ u: CGFloat, _ v: CGFloat, _ h: CGFloat = 0) -> CGPoint {
            CGPoint(x: A.x + u * (Bc.x - A.x) + v * (D.x - A.x), y: A.y + u * (Bc.y - A.y) + v * (D.y - A.y) - h)
        }
        let factory = s.kind == "factory", chat = s.kind == "chats"
        let floorCol = factory ? SKColor(red: 0.16, green: 0.2, blue: 0.25, alpha: 1) : chat ? SKColor(red: 0.91, green: 0.82, blue: 0.69, alpha: 1)
            : SKColor(red: 0.79, green: 0.64, blue: 0.48, alpha: 1)
        n.addChild(shape([A, Bc, C, D], fill: floorCol, stroke: Self.ink, width: 0.8 * px))
        // a lighter band where the walls were cut, so it reads as a section
        let rim = shape([A, Bc, Q(1, 0.06), Q(0, 0.06)], fill: SKColor(white: 1, alpha: 0.18)); n.addChild(rim)
        // (the people and desks are in the room itself, seen through the facade: the ceiling stays a quiet slab)
        return n
    }

    /// The room inside a storey, seen through its faded facade (D74): the floor, the two far walls with their windows,
    /// two rows of desks with screens, and someone at a desk for each session at work.
    func room(_ s: CampusArt.Storey, _ p: Project, world: World) -> SKNode {
        let n = SKNode()
        guard s.faces.count == 2 else { return n }
        // the storey's corners: front-left (A), front corner (B), right (C), back (D), on its floor and its ceiling
        let A = s.faces[0][0], B = s.faces[0][1], C = s.faces[1][1], up = s.faces[0][3].y - A.y
        let D = CGPoint(x: A.x + C.x - B.x, y: A.y + C.y - B.y)
        func Q(_ u: CGFloat, _ v: CGFloat, _ h: CGFloat = 0) -> CGPoint {
            CGPoint(x: A.x + u * (B.x - A.x) + v * (D.x - A.x), y: A.y + u * (B.y - A.y) + v * (D.y - A.y) - h)
        }
        let factory = s.kind == "factory", chat = s.kind == "chats"
        let floor = factory ? SKColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1) : chat ? SKColor(red: 0.85, green: 0.74, blue: 0.6, alpha: 1) : SKColor(red: 0.72, green: 0.56, blue: 0.4, alpha: 1)
        let wall = factory ? SKColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1) : SKColor(red: 0.9, green: 0.84, blue: 0.76, alpha: 1)
        let wallSide = factory ? SKColor(red: 0.13, green: 0.15, blue: 0.2, alpha: 1) : SKColor(red: 0.8, green: 0.74, blue: 0.67, alpha: 1)
        // the far walls: along the back (D to C) and down the left (A to D), floor to ceiling
        n.addChild(shape([D, C, CGPoint(x: C.x, y: C.y + up), CGPoint(x: D.x, y: D.y + up)], fill: wall, stroke: Self.ink, width: 0.6 * px))
        n.addChild(shape([A, D, CGPoint(x: D.x, y: D.y + up), CGPoint(x: A.x, y: A.y + up)], fill: wallSide, stroke: Self.ink, width: 0.6 * px))
        let glass = factory ? SKColor(red: 0.35, green: 0.65, blue: 0.85, alpha: 1) : SKColor(red: 0.3, green: 0.36, blue: 0.6, alpha: 1)
        for t in stride(from: 0.12 as CGFloat, to: 0.9, by: 0.26) {
            let a = CGPoint(x: D.x + (C.x - D.x) * t, y: D.y + (C.y - D.y) * t), b = CGPoint(x: D.x + (C.x - D.x) * (t + 0.16), y: D.y + (C.y - D.y) * (t + 0.16))
            n.addChild(shape([CGPoint(x: a.x, y: a.y + up * 0.3), CGPoint(x: b.x, y: b.y + up * 0.3), CGPoint(x: b.x, y: b.y + up * 0.75), CGPoint(x: a.x, y: a.y + up * 0.75)], fill: glass))
        }
        n.addChild(shape([A, B, C, D], fill: floor, stroke: Self.ink, width: 0.6 * px))
        // desks in two rows, a screen on each, and someone at the busy ones
        let busy = p.sessions.filter { $0.state(now: world.now) != .done }.prefix(8)
        let shirts: [SKColor] = [SKColor(red: 0.29, green: 0.45, blue: 0.85, alpha: 1), SKColor(red: 0.25, green: 0.68, blue: 0.42, alpha: 1),
                                 SKColor(red: 0.91, green: 0.38, blue: 0.54, alpha: 1), SKColor(red: 0.48, green: 0.36, blue: 0.88, alpha: 1)]
        let seats: [(CGFloat, CGFloat)] = [(0.2, 0.62), (0.45, 0.62), (0.7, 0.62), (0.9, 0.62), (0.2, 0.3), (0.45, 0.3), (0.7, 0.3), (0.9, 0.3)]
        for (k, (u, v)) in seats.enumerated() {
            let top: CGFloat = 5
            n.addChild(shape([Q(u - 0.08, v, top), Q(u + 0.08, v, top), Q(u + 0.08, v + 0.12, top), Q(u - 0.08, v + 0.12, top)],
                             fill: SKColor(red: 0.42, green: 0.29, blue: 0.19, alpha: 1), stroke: Self.ink, width: 0.5 * px))
            let on = k < busy.count
            let screen = factory ? SKColor(red: 0.5, green: 0.84, blue: 1, alpha: 1) : SKColor(red: 0.4, green: 0.6, blue: 0.95, alpha: 1)
            n.addChild(shape([Q(u - 0.06, v + 0.11, top), Q(u + 0.06, v + 0.11, top), Q(u + 0.06, v + 0.11, top + 7), Q(u - 0.06, v + 0.11, top + 7)],
                             fill: on ? screen : SKColor(red: 0.2, green: 0.2, blue: 0.27, alpha: 1), stroke: Self.ink, width: 0.5 * px))
            guard on else { continue }
            let s = busy[busy.startIndex + k], foot = Q(u, v - 0.06)
            let body = SKShapeNode(rectOf: CGSize(width: 5 * px, height: 7 * px), cornerRadius: 1.2 * px)
            body.fillColor = shirts[k % shirts.count]; body.strokeColor = Self.ink; body.lineWidth = 0.6 * px
            body.position = scenePoint(CGPoint(x: foot.x, y: foot.y - 5))
            let head = SKShapeNode(rectOf: CGSize(width: 5 * px, height: 5 * px), cornerRadius: 0.8 * px)
            head.fillColor = SKColor(red: 0.95, green: 0.71, blue: 0.54, alpha: 1); head.strokeColor = Self.ink; head.lineWidth = 0.6 * px
            head.position = scenePoint(CGPoint(x: foot.x, y: foot.y - 11))
            n.addChild(body); n.addChild(head)
            if s.state(now: world.now) == .waiting {
                let dot = SKShapeNode(rectOf: CGSize(width: 3.4 * px, height: 3.4 * px)); dot.fillColor = Self.wait; dot.strokeColor = Self.ink; dot.lineWidth = 0.6 * px
                dot.position = scenePoint(CGPoint(x: foot.x + 4, y: foot.y - 17)); n.addChild(dot)
            }
        }
        return n
    }

    /// Where the pointer is, in tower terms: a tower (or one of its storeys) wants to stand apart. While one is apart
    /// it stays so over its whole spread, gaps included.
    func wantApart(_ t: Target?, at p: CGPoint?) {
        var want: String?
        switch t {
        case .building(let k)?: want = stacks[k] != nil ? k : nil
        case .storey(let id)?: want = storeys.first { $0.project == id }.map(\.storey.building)
        default: break
        }
        if want == nil, let p {
            for (k, st) in stacks where st.target == 1 && st.e > 0.05 {
                var r = buildings[k]?.calculateAccumulatedFrame() ?? .null
                for (i, sg) in signs.enumerated() where sg.owner == k && i < signHome.count { r = r.union(sg.node.frame) }
                if r.insetBy(dx: -8 * px, dy: -8 * px).contains(p) { want = k }
            }
        }
        if want != explodeShut { explodeShut = nil }
        explodeWant = want
    }

    /// Esc: a tower apart goes back together (and stays so until the pointer leaves it).
    func closeStacks() -> Bool {
        guard let st = stacks.values.first(where: { $0.target == 1 }) else { return false }
        st.target = 0; explodeShut = st.key; wheelMark = nil
        return true
    }

    /// The wheel over a tower apart walks the mark through its storeys, one per notch (or per stretch of trackpad).
    func stackWheel(_ dy: CGFloat, precise: Bool) -> Bool {
        guard let st = stacks.values.first(where: { $0.target == 1 && $0.e > 0.5 }), !st.pieces.isEmpty else { return false }
        wheelRest += precise ? dy / 14 : dy
        let steps = Int(wheelRest.rounded(.towardZero))
        guard steps != 0 else { return true }
        wheelRest -= CGFloat(steps)
        let start: Int
        if let m = wheelMark, m.key == st.key { start = m.index }
        else if case .storey(let id)? = hoverTarget, let s = storeys.first(where: { $0.project == id && $0.storey.building == st.key }) { start = s.storey.index }
        else { start = steps > 0 ? -1 : st.pieces.count }
        let k = max(0, min(st.pieces.count - 1, start + steps))
        wheelMark = (st.key, k, pointer ?? .zero)
        hover(at: pointerInScene)
        return true
    }

    /// Beside the marked storey, on the side away from the plaques (they hang to the right): its line hangs there, in
    /// view points from the top left.
    func markLabelPoint() -> CGPoint? {
        guard let m = wheelMark, let v = view, let s = storeys.first(where: { $0.storey.building == m.key && $0.storey.index == m.index })?.storey,
              let f = s.faces.first, f.count == 4 else { return nil }
        let off = stacks[m.key]?.offset(m.index) ?? 0
        let left = CGPoint(x: f[0].x - 6, y: (f[0].y + f[3].y) / 2 - off)
        let q = convertPoint(toView: scenePoint(left))
        return CGPoint(x: q.x, y: v.bounds.height - q.y)
    }

    /// Window shots: hold a tower apart, and mark one of its storeys as the wheel would.
    public func holdApart(_ key: String?) { pinnedApart = key }
    public func mark(_ index: Int) {
        guard let key = pinnedApart, let st = stacks[key], st.pieces.indices.contains(index) else { return }
        wheelMark = (key, index, pointer ?? .zero)
        hover(at: pointerInScene)
    }

    /// A storey's faces where they are now (lifted when apart), hit at a point in art units.
    func storeyHit(_ s: CampusArt.Storey, _ a: CGPoint) -> Bool {
        let off = stacks[s.building]?.offset(s.index) ?? 0
        let q = CGPoint(x: a.x, y: a.y + off)
        return s.faces.contains { contains($0, q) }
    }

    /// The cut under a storey (the gap below the one above it), while its tower stands apart.
    func cutHit(_ s: CampusArt.Storey, _ a: CGPoint) -> Bool {
        guard s.faces.count == 2, let st = stacks[s.building] else { return false }
        let A = s.faces[0][3], B = s.faces[0][2], C = s.faces[1][2], g = max(0, st.offset(s.index + 1) - st.offset(s.index))
        let q = CGPoint(x: a.x, y: a.y + st.offset(s.index))
        return contains([A, B, C, CGPoint(x: C.x, y: C.y - g), CGPoint(x: B.x, y: B.y - g), CGPoint(x: A.x, y: A.y - g)], q)
    }

    /// Every frame: open the wanted tower after a short dwell, close one the pointer left after a short while, ease
    /// toward that, and move the pieces, their overlay layers, their plaques and any outline on them.
    func tickStacks(_ dt: Double) {
        for (key, st) in stacks {
            let wants = (explodeWant == key && explodeShut != key) || pinnedApart == key
            if wants { st.wantFor += dt; st.awayFor = 0 } else { st.awayFor += dt; st.wantFor = 0 }
            if wants, st.wantFor >= 0.2, st.target == 0 { st.target = 1; st.since = 0; st.gap = fitGap(st) }
            if !wants, st.awayFor >= 0.35, st.target == 1 { st.target = 0; st.since = 0; if wheelMark?.key == key { wheelMark = nil } }
            let was = st.pos
            st.since += dt
            // the storey that comes loose: the wheel's mark, else the one under the pointer (its faces or its cut)
            var hot: Int?
            if st.target == 1 {
                if let m = wheelMark, m.key == key { hot = m.index }
                else if let p = pointerInScene {
                    let a = artPoint(p), mine = storeys.filter { $0.storey.building == key }.map(\.storey)
                    hot = (mine.first { storeyHit($0, a) } ?? mine.first { cutHit($0, a) })?.index
                }
            }
            st.hot = hot
            let goals: [CGFloat] = st.pos.indices.map { k in
                guard st.target == 1, let h = hot else { return 0 }
                return k < h ? 0 : k == h ? TowerStack.loose : TowerStack.above
            }
            if animationsEnabled && dt > 0 {
                // a spring per piece, a little under-damped: it comes loose with one bounce; back together it lands
                // with a thunk (no bounce into the storey below)
                let h = CGFloat(min(dt, 1.0 / 30))
                for k in st.pos.indices {
                    let goal = goals[k]
                    st.vel[k] += (240 * (goal - st.pos[k]) - 17 * st.vel[k]) * h
                    st.pos[k] += st.vel[k] * h
                    if st.pos[k] < 0 { st.pos[k] = 0; st.vel[k] = 0 }
                    if abs(goal - st.pos[k]) < 0.001, abs(st.vel[k]) < 0.01 { st.pos[k] = goal; st.vel[k] = 0 }
                }
            } else {
                for k in st.pos.indices { st.pos[k] = goals[k]; st.vel[k] = 0 }
            }
            // see into the loose storey once it has come loose
            for k in st.seeIn.indices {
                let goal: CGFloat = st.target == 1 && hot == k ? 1 : 0
                st.seeIn[k] = animationsEnabled && dt > 0 ? st.seeIn[k] + (goal - st.seeIn[k]) * CGFloat(min(1, dt * 8)) : goal
                if abs(goal - st.seeIn[k]) < 0.005 { st.seeIn[k] = goal }
            }
            guard st.pos != was || st.e > 0 || st.seeIn.contains(where: { $0 > 0 }) else { continue }
            // the camera stays where it is: the world never shifts under you (the gap fits the room instead)
            place(st)
        }
    }

    /// The gap that fits the room above the tower under the top bar (12 to 24 art units): the tower grows into the view,
    /// the camera never moves.
    private func fitGap(_ st: TowerStack) -> CGFloat {
        guard let b = buildings[st.key] else { return 14 }
        let viewTop = cam.position.y + size.height / 2 * cam.yScale - 80 * cam.yScale
        let room = (viewTop - b.frame.maxY) / px
        return max(12, min(24, room / TowerStack.above))
    }

    private func place(_ st: TowerStack) {
        guard let b = buildings[st.key] else { return }
        let apart = st.pos.contains { $0 > 0.0005 }
        st.root.isHidden = !apart
        b.texture = apart ? Self.clearTexture : st.texture
        for s in st.sprites { s.color = b.color; s.colorBlendFactor = b.colorBlendFactor }
        for (k, n) in st.pieces.enumerated() { n.position.y = st.offset(k) * px }
        // the loose storey's facade fades to a glass ghost and its room shows behind it (D74)
        for k in st.facades.indices where k < st.seeIn.count {
            let v = st.seeIn[k]
            st.facades[k].alpha = 1 - 0.8 * v
            st.insides[k].alpha = v; st.insides[k].isHidden = v < 0.01
            layer(st.key, storey: k)?.alpha = 1 - 0.85 * v
        }
        st.roof?.position.y = st.roofOffset * px
        for k in st.pieces.indices { layer(st.key, storey: k)?.position.y = st.offset(k) * px }
        layer(st.key, storey: nil)?.position.y = st.roofOffset * px
        for (i, sg) in signs.enumerated() where sg.owner == st.key && i < signHome.count {
            let off = sg.plaque ? sg.storey.map { st.offset($0) } ?? 0 : st.roofOffset
            sg.node.position = CGPoint(x: signHome[i].x, y: signHome[i].y + off * px)
        }
        // an outline on a storey of this tower goes with it
        func lift(_ id: String?, _ n: SKNode?) {
            guard let id, let n, let s = storeys.first(where: { $0.project == id }), s.storey.building == st.key else { return }
            n.position.y = st.offset(s.storey.index) * px
        }
        if case .storey(let id)? = hoverTarget { lift(id, hoverLayer) }
        lift(highlightID, highlight)
    }
}
