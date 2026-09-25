package com.zoaz.bow;

import java.util.HashMap;
import java.util.List;

import me.zed_0xff.zombie_buddy.Exposer;
import zombie.core.opengl.Shader;
import zombie.core.textures.ColorInfo;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.SpriteModel;
import zombie.iso.sprite.IsoSprite;
import zombie.scripting.ScriptManager;

/**
 * The 3D display entity for an arrow in flight.
 *
 * <h2>Why this class exists</h2>
 * A dropped arrow (WorldStaticModel = BAS_Arrow in the item script) is rendered by
 * {@code IsoWorldInventoryObject}, which has <b>no angle interface at all</b>
 * (IsoObject only has setDir(int), which switches between discrete sprite variants), so the model orientation is fixed forever.
 * For the arrow head to turn with the flight direction a custom entity is the only way: its {@code SpriteModel.rotate}
 * is read by {@code IsoObjectModelDrawer} every frame and fed into the transform matrix.
 *
 * <h2>Why the base class is IsoMovingObject and not IsoObject</h2>
 * {@code IsoObject.getX()} returns {@code square.getX()} directly (whole-tile coordinates), and rendering
 * hardcodes the position as {@code renderModel(x + 0.5F, y + 0.5F, z)} -- in other words a plain IsoObject
 * can only be placed on whole tiles. An arrow moves 0.35 of a tile per frame, so with IsoObject it would jump tile by tile.
 * {@code IsoMovingObject} carries its own float x/y/z (it overrides getX/setX),
 * so it can move continuously. (Note: what registers into {@code IsoCell.objectList} is the <b>constructor</b>
 * second parameter, not {@code addToWorld()} -- see the three registration steps below.)
 *
 * <h2>How the model gets attached</h2>
 * {@code IsoObject.spriteModel} is protected, so a subclass can simply assign the field;
 * when rendering, {@code IsoObjectModelDrawer} uses {@code spriteModel.modelScriptName}
 * to look it up in {@code ScriptManager.getModelScript(...)}, so pointing that name at the model
 * script {@code Base.BAS_Arrow} (see models_arrow.txt) is all it takes to display the arrow mesh.
 *
 * <h2>Two easy traps</h2>
 * <ul>
 *   <li><b>scales multiply</b>: {@code modelScript.scale * spriteModel.scale}.
 *       The model script is already 0.01, so spriteModel.scale here must be 1.0,
 *       otherwise the model comes out 100 times too big.</li>
 *   <li><b>It has to be a private copy</b>: take the SpriteModel from the shared script object and changing
 *       rotate turns every object on the map that uses the same model. Here each entity allocates its own.</li>
 * </ul>
 *
 * <h2>The three registration steps behind "the arrow is completely invisible" (fixed 2026-09-19)</h2>
 * A custom IsoMovingObject has to complete three registration steps before it is drawn; <b>missing any one
 * means "the object exists, probe says FOUND, spawn returned a non-zero id, and the screen shows nothing"</b>:
 * <ol>
 *   <li>{@code super(sprite, true)} in the constructor -- only true gets it into
 *       {@code IsoCell.objectList} (IsoMovingObject:181-187); and the one channel that renders moving
 *       objects under FBO, {@code FBORenderCell.renderMovingObjects()}:3364-3371,
 *       walks exactly that list.</li>
 *   <li>{@code setCurrent(sq)} every frame -- the hard gate at {@code renderMovingObject()}:3378,
 *       {@code if (getCurrentSquare() == null) return;}, reads the current field.
 *       Note that {@code IsoObject.setSquare()} <b>only assigns the square field</b> and never touches current.</li>
 *   <li>{@code setMovingSquare(sq)} every frame -- this is the step that adds the object to
 *       {@code sq.getMovingObjects()} (used by the non-FBO
 *       {@code IsoGridSquare.renderCharacters()}:6801).</li>
 * </ol>
 * Also: once it is in objectList the engine update loop takes it over
 * (after preupdate/frameStep/update, postupdate moves the position back by {@code nextX - x}),
 * so those three hooks must be empty and the position belongs to the Lua pose() call alone;
 * {@code collidable} has to be off as well.
 *
 * <h2>How Lua calls in</h2>
 * {@code @Exposer.LuaClass(name = "BowAPI.BowArrow3D")} exposes it as
 * {@code BowAPI.BowArrow3D}, so Lua writes {@code BowAPI.BowArrow3D.spawn(...)}.
 * Every parameter and return value is a double (Kahlua handles Integer poorly).
 */
@Exposer.LuaClass(name = "BowAPI.BowArrow3D")
public final class BowArrow3D {

    /**
     * Model script name -- resolved at runtime, never hard-coded.
     *
     * The item path already proves which spelling the engine accepts: the item
     * scripts write {@code WorldStaticModel = BAS_Arrow} (no module prefix) and
     * that renders fine, so ItemModelRenderer's
     * {@code ScriptManager.getModelScript("BAS_Arrow")} is a hit. The qualified
     * form is kept as a fallback for other module layouts.
     *
     * Hard-coding the wrong one made IsoObject.renderModel() return false, and
     * a false there is SILENT: the object just falls back to drawing its
     * carrier sprite instead of the model, so the arrow was invisible both in
     * flight and after landing.
     */
    private static String resolvedModelScript;

    private static String modelScript() {
        if (resolvedModelScript == null) {
            resolvedModelScript = "BAS_Arrow";
            String[] candidates = {"BAS_Arrow", "Base.BAS_Arrow"};
            for (int i = 0; i < candidates.length; i++) {
                try {
                    if (ScriptManager.instance.getModelScript(candidates[i]) != null) {
                        resolvedModelScript = candidates[i];
                        break;
                    }
                } catch (Throwable t) {
                    // try the next spelling
                }
            }
        }
        return resolvedModelScript;
    }

    private static final HashMap<Long, ArrowBody> LIVE = new HashMap<Long, ArrowBody>();
    private static long nextId = 1L;

    /** One-shot diagnostic flag ([BowAPI] arrow3d diag) -- delete it with that block once the arrow is confirmed visible. */
    private static boolean DIAG_DONE;

    /** Borrowed carrier sprite: only there to satisfy the IsoObject sprite field (the model is decided by spriteModel). */
    private static IsoSprite carrier;

    private BowArrow3D() {
    }

    /** One arrow in flight. Each instance owns its SpriteModel, so they rotate independently. */
    private static final class ArrowBody extends IsoMovingObject {

        private SpriteModel ownModel;

        ArrowBody(IsoSprite sprite) {
            // CAUTION: the second parameter must be true (fixed 2026-09-19).
            // IsoMovingObject(IsoSprite, boolean) registers itself in IsoCell.objectList only when this
            // parameter is true (IsoMovingObject.java:181-187), and under FBO the ONLY channel that
            // renders moving objects is a walk of that list:
            //   FBORenderCell.renderMovingObjects() :3364-3371
            //     for (IsoMovingObject o : IsoWorld.instance.getCell().getObjectList())
            // and a 3D model has to go through FBO anyway (IsoObject.renderModel() :5777 requires
            // PerformanceSettings.fboRenderChunk on its first line).
            // With false the object really is created, probe() says FOUND and spawn() returns a non-zero
            // id, but NO rendering channel can see it -- the symptom is "no arrow in flight, on the ground
            // or in a wall", while damage still works (Lua computes damage separately).
            super(sprite, true);
            // The position is 100% driven by Lua's pose(): the engine must never run collision on it.
            // IsoMovingObject.collidable defaults to true.
            this.setCollidable(false);
        }

        @Override
        public SpriteModel getSpriteModel() {
            if (this.ownModel == null) {
                SpriteModel sm = new SpriteModel();
                sm.modelScriptName = modelScript();
                // 1.0 is deliberate: modelScript.scale(0.01) * 1.0 = 0.01
                sm.scale = 1.0f;
                this.ownModel = sm;
            }
            return this.ownModel;
        }

        void pose(float nx, float ny, float nz, float yawDeg, float pitchDeg) {
            this.setX(nx);
            this.setY(ny);
            this.setZ(nz);
            SpriteModel m = this.getSpriteModel();
            if (m != null && m.rotate != null) {
                // The engine reads rotate.x / -rotate.y / rotate.z and applies them in order.
                // Rotating about X does not change the +X heading, so pitch goes to Y and horizontal heading to Z.
                m.rotate.set(0.0f, pitchDeg, yawDeg);
            }
            IsoCell c = IsoWorld.instance.getCell();
            if (c == null) {
                return;
            }
            IsoGridSquare ns = c.getGridSquare(nx, ny, nz);
            if (ns == null || ns == this.getCurrentSquare()) {
                return;
            }
            // CAUTION: all three are required (fixed 2026-09-19 -- only setSquare() used to be called,
            //    and IsoObject.setSquare() is a single `this.square = square;`, so neither of the two
            //    registrations the render side needs was ever done):
            //   setCurrent      -> the hard gate at FBORenderCell.renderMovingObject() :3378
            //                      `if (getCurrentSquare() == null) return;`
            //                      it reads the current field, not the square field
            //   setMovingSquare -> adds this object to ns.getMovingObjects(). The non-FBO
            //                      IsoGridSquare.renderCharacters() :6801 and the FBO shadow/corpse
            //                      flag collection :1283 both rely on that list
            //   setSquare       -> keeps the old field in sync so getSquare()/isOnScreen() agree
            this.setCurrent(ns);
            this.setMovingSquare(ns);
            this.setSquare(ns);
        }

        // ---- the engine moving-object simulation must yield entirely to Lua ----------------
        // Once in objectList, MovingObjectUpdateSchedulerUpdateBucket.update() calls
        // preupdate() / frameStep() / update() every frame, and then postupdate() moves the object
        // back by `dx = nextX - x` (IsoMovingObject :934-942).
        // Lua's pose() runs exactly between preupdate and postupdate (OnPlayerUpdate is fired from
        // IsoPlayer.update()), so without emptying those hooks every frame of movement
        // would be undone by postupdate and the arrow would stick at the launch point.
        // Emptying update() as well has a useful side effect: IsoMovingObject.update() calls
        // sprite.update(def) on the borrowed carrier sprite, which mutates the shared
        // IsoSpriteInstance.
        @Override
        public void preupdate() {
        }

        @Override
        public void update() {
        }

        @Override
        public void postupdate() {
        }

        // ---- rendering: deliberately NOT using the IsoObject.render() +0.5 convention ---------
        // IsoObject.render() turns into renderModel(x + 0.5f, y + 0.5f, z, col)
        // (IsoObject :3388); that half tile exists to move a whole-tile-corner object to the tile centre
        // (FBORenderCell :2439 passes square.x / square.y). Our x/y are already
        // world floats (i.e. tile centres), so another +0.5 shifts the whole model half a tile.
        // Every vanilla moving object with float coordinates overrides render instead of following it
        // (IsoDeadBody :1071 calls IsoUtils.XToScreen(x, y, z, 0) directly).
        // There is NO fallback to the carrier sprite here either -- that would paint a borrowed floor/wall texture in mid air.
        @Override
        public void render(float x, float y, float z, ColorInfo col, boolean bDoAttached,
                boolean bWallLightingPass, Shader shader) {
            if (!this.getDoRender() || this.isSceneCulled()) {
                return;
            }
            this.renderModel(x, y, z, col);
        }
    }

    /**
     * Find an existing sprite to use as a carrier. Taking one from a real nearby object avoids the
     * missing texture/properties problems that inventing a sprite brings.
     */
    private static IsoSprite findCarrier(IsoCell cell, int px, int py, int pz) {
        if (carrier != null) {
            return carrier;
        }
        for (int r = 0; r <= 3; r++) {
            for (int dx = -r; dx <= r; dx++) {
                for (int dy = -r; dy <= r; dy++) {
                    IsoGridSquare s = cell.getGridSquare(px + dx, py + dy, pz);
                    if (s == null) {
                        continue;
                    }
                    List<IsoObject> objs = s.getObjects();
                    for (int i = 0; i < objs.size(); i++) {
                        IsoObject o = objs.get(i);
                        if (o != null && o.getSprite() != null) {
                            carrier = o.getSprite();
                            return carrier;
                        }
                    }
                }
            }
        }
        return null;
    }

    /** Spawn an arrow in flight, returns its id (0 = failure). */
    public static double spawn(double x, double y, double z, double yawDeg, double pitchDeg) {
        try {
            IsoCell cell = IsoWorld.instance.getCell();
            if (cell == null) {
                return 0.0;
            }
            IsoGridSquare sq = cell.getGridSquare((float) x, (float) y, (float) z);
            if (sq == null) {
                return 0.0;
            }
            IsoSprite sp = findCarrier(cell, sq.getX(), sq.getY(), sq.getZ());
            if (sp == null) {
                return 0.0;
            }
            ArrowBody o = new ArrowBody(sp);
            o.setSquare(sq);
            o.setX((float) x);
            o.setY((float) y);
            o.setZ((float) z);
            o.addToWorld();
            o.pose((float) x, (float) y, (float) z, (float) yawDeg, (float) pitchDeg);
            // TEMP DIAG (delete once the arrow is confirmed visible): report the three steps once.
            // These three lines are the single dividing line of "the arrow is invisible":
            //   all three true  -> registration is fine; if it is still invisible the problem is model/texture
            //   any one false   -> whatever this section fixed did not take effect
            if (!DIAG_DONE) {
                DIAG_DONE = true;
                IsoGridSquare cs = o.getCurrentSquare();
                System.out.println("[BowAPI] arrow3d diag -> inObjectList="
                        + (cell.getObjectList().contains(o) || cell.getAddList().contains(o))
                        + " currentSquare=" + (cs != null)
                        + " inSquareMovingObjects=" + (cs != null && cs.getMovingObjects().contains(o))
                        + " collidable=" + o.isCollidable());
            }
            long id = nextId++;
            LIVE.put(Long.valueOf(id), o);
            return (double) id;
        } catch (Throwable t) {
            return 0.0;
        }
    }

    /** Move an arrow to a new position and set its heading. Called by Lua every frame of the trajectory. */
    public static void pose(double id, double x, double y, double z, double yawDeg, double pitchDeg) {
        ArrowBody o = LIVE.get(Long.valueOf((long) id));
        if (o == null) {
            return;
        }
        try {
            o.pose((float) x, (float) y, (float) z, (float) yawDeg, (float) pitchDeg);
        } catch (Throwable t) {
            // best effort
        }
    }

    /** Destroy an arrow display entity (called when it stops or hits). */
    public static void destroy(double id) {
        ArrowBody o = LIVE.remove(Long.valueOf((long) id));
        if (o == null) {
            return;
        }
        try {
            // Both steps are needed (removeFromSquare added 2026-09-19):
            //   removeFromWorld()  -> detaches only from IsoCell.objectList / addList / removeList
            //                         and MovingObjectUpdateScheduler; it does NOT touch
            //                         current/last or square.getMovingObjects()
            //   removeFromSquare() -> those two are its job (IsoMovingObject :702-716)
            // Without the second call, every arrow that hits or is picked up leaves a permanent reference
            // on the square: a memory leak, and that square keeps answering false to isFree(true)
            // (zombie spawning, room selection and similar queries are all affected).
            o.removeFromWorld();
            o.removeFromSquare();
        } catch (Throwable t) {
            // best effort
        }
    }

    /** Number of arrows currently alive. */
    public static double count() {
        return (double) LIVE.size();
    }

    /** Clear every arrow (save switching / debugging). */
    public static void clear() {
        Long[] keys = LIVE.keySet().toArray(new Long[0]);
        for (int i = 0; i < keys.length; i++) {
            destroy(keys[i].longValue());
        }
        LIVE.clear();
    }

    /** Probe: whether the model script resolves and whether a carrier sprite was obtained. */
    public static String probe() {
        StringBuilder sb = new StringBuilder();
        String[] candidates = {"BAS_Arrow", "Base.BAS_Arrow"};
        for (int i = 0; i < candidates.length; i++) {
            try {
                Object ms = ScriptManager.instance.getModelScript(candidates[i]);
                sb.append(candidates[i]).append("=").append(ms != null ? "FOUND" : "null").append("; ");
            } catch (Throwable t) {
                sb.append(candidates[i]).append("=EX; ");
            }
        }
        sb.append("using=").append(modelScript());
        sb.append(" carrier=").append(carrier != null ? carrier.getName() : "none");
        sb.append(" live=").append(LIVE.size());
        return sb.toString();
    }
}
