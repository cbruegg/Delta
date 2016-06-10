//
//  EmulationViewController.swift
//  Delta
//
//  Created by Riley Testut on 5/5/15.
//  Copyright (c) 2015 Riley Testut. All rights reserved.
//

import UIKit

import DeltaCore
import Roxas

// Temporary wrapper around dispatch_semaphore_t until Swift 3 + modernized libdispatch
private struct DispatchSemaphore: Hashable
{
    let semaphore: dispatch_semaphore_t
    
    var hashValue: Int {
        return semaphore.hash
    }
    
    init(value: Int)
    {
        self.semaphore = dispatch_semaphore_create(value)
    }
}

private func ==(lhs: DispatchSemaphore, rhs: DispatchSemaphore) -> Bool
{
    return lhs.semaphore.isEqual(rhs.semaphore)
}

class EmulationViewController: UIViewController
{
    //MARK: - Properties -
    /** Properties **/
    
    /// Should only be set when preparing for segue. Otherwise, should be considered immutable
    var game: Game! {
        didSet
        {
            guard oldValue != game else { return }

            self.emulatorCore = EmulatorCore(game: game)
            
        }
    }
    private(set) var emulatorCore: EmulatorCore! {
        didSet
        {
            // Cannot set directly, or else we're left with a strong reference cycle
            //self.emulatorCore.updateHandler = emulatorCoreDidUpdate
            
            self.emulatorCore.updateHandler = { [weak self] core in
                self?.emulatorCoreDidUpdate(core)
            }
            
            self.preferredContentSize = self.emulatorCore.preferredRenderingSize
        }
    }
    
    // If non-nil, will override the default preview action items returned in previewActionItems()
    var overridePreviewActionItems: [UIPreviewActionItem]?
    
    // Annoying iOS gotcha: if the previewingContext(_:viewControllerForLocation:) callback takes too long, the peek/preview starts, but fails to actually present the view controller
    // To workaround, we have this closure to defer work for Peeking/Popping until the view controller appears
    // Hacky, but works
    var deferredPreparationHandler: (Void -> Void)?
    
    //MARK: - Private Properties
    private var pauseViewController: PauseViewController?
    private var pausingGameController: GameControllerProtocol?
    
    private var context = CIContext(options: [kCIContextWorkingColorSpace: NSNull()])

    private var updateSemaphores = Set<DispatchSemaphore>()
    
    private var sustainedInputs = [ObjectIdentifier: [InputType]]()
    private var reactivateSustainInputsQueue: NSOperationQueue
    private var choosingSustainedButtons = false
    
    @IBOutlet private var controllerView: ControllerView!
    @IBOutlet private var gameView: GameView!
    @IBOutlet private var sustainButtonContentView: UIView!
    @IBOutlet private var backgroundView: RSTBackgroundView!
    
    @IBOutlet private var controllerViewHeightConstraint: NSLayoutConstraint!
    
    
    //MARK: - Initializers -
    /** Initializers **/
    required init?(coder aDecoder: NSCoder)
    {
        self.reactivateSustainInputsQueue = NSOperationQueue()
        self.reactivateSustainInputsQueue.maxConcurrentOperationCount = 1
        
        super.init(coder: aDecoder)
                
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(EmulationViewController.updateControllers), name: ExternalControllerDidConnectNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(EmulationViewController.updateControllers), name: ExternalControllerDidDisconnectNotification, object: nil)
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(EmulationViewController.willResignActive(_:)), name: UIApplicationWillResignActiveNotification, object: UIApplication.sharedApplication())
         NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(EmulationViewController.didBecomeActive(_:)), name: UIApplicationDidBecomeActiveNotification, object: UIApplication.sharedApplication())
    }
    
    deinit
    {
        // To ensure the emulation stops when cancelling a peek/preview gesture
        self.emulatorCore.stopEmulation()
    }
    
    //MARK: - Overrides
    /** Overrides **/
    
    //MARK: - UIViewController
    /// UIViewController
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Set this to 0 now and update it in viewDidLayoutSubviews to ensure there are never conflicting constraints
        // (such as when peeking and popping)
        self.controllerViewHeightConstraint.constant = 0
        
        self.gameView.backgroundColor = UIColor.clearColor()
        self.emulatorCore.addGameView(self.gameView)
        
        self.backgroundView.textLabel.text = NSLocalizedString("Select Buttons to Sustain", comment: "")
        self.backgroundView.detailTextLabel.text = NSLocalizedString("Press the Menu button when finished.", comment: "")
        
        let controllerSkin = ControllerSkin.defaultControllerSkinForGameUTI(self.game.typeIdentifier)
        
        self.controllerView.containerView = self.view
        self.controllerView.controllerSkin = controllerSkin
        
        self.updateControllers()
    }
    
    override func viewDidAppear(animated: Bool)
    {
        super.viewDidAppear(animated)
        
        self.deferredPreparationHandler?()
        self.deferredPreparationHandler = nil
        
        // Yes, order DOES matter here, in order to prevent audio from being slightly delayed after peeking with 3D Touch (ugh so tired of that issue)
        switch self.emulatorCore.state
        {
        case .Stopped:
            self.emulatorCore.startEmulation()
            self.updateCheats()
            
        case .Running: break
        case .Paused:
            self.updateCheats()
            self.resumeEmulation()
        }
        
        // Toggle audioManager.enabled to reset the audio buffer and ensure the audio isn't delayed from the beginning
        // This is especially noticeable when peeking a game
        self.emulatorCore.audioManager.enabled = false
        self.emulatorCore.audioManager.enabled = true
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        if Settings.localControllerPlayerIndex != nil && self.controllerView.intrinsicContentSize() != CGSize(width: UIViewNoIntrinsicMetric, height: UIViewNoIntrinsicMetric) && !self.isPreviewing
        {
            let scale = self.view.bounds.width / self.controllerView.intrinsicContentSize().width
            self.controllerViewHeightConstraint.constant = self.controllerView.intrinsicContentSize().height * scale
        }
        else
        {
            self.controllerViewHeightConstraint.constant = 0
        }
        
        self.controllerView.hidden = self.isPreviewing
    }
    
    override func prefersStatusBarHidden() -> Bool
    {
        return true
    }
    
    /// <UIContentContainer>
    override func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator)
    {
        super.viewWillTransitionToSize(size, withTransitionCoordinator: coordinator)
        
        self.controllerView.beginAnimatingUpdateControllerSkin()
        
        coordinator.animateAlongsideTransition({ _ in
            
            if self.emulatorCore.state == .Paused
            {
                // We need to manually "refresh" the game screen, otherwise the system tries to cache the rendered image, but skews it incorrectly when rotating b/c of UIVisualEffectView
                self.gameView.inputImage = self.gameView.outputImage
            }
            
        }, completion: { _ in
                self.controllerView.finishAnimatingUpdateControllerSkin()
        })
    }
    
    // MARK: - Navigation -
    
    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?)
    {
        self.pauseEmulation()
        
        if segue.identifier == "pauseSegue"
        {
            guard let gameController = sender as? GameControllerProtocol else { fatalError("sender for pauseSegue must be the game controller that pressed the Menu button") }
            
            self.pausingGameController = gameController
            
            let pauseViewController = segue.destinationViewController as! PauseViewController
            pauseViewController.pauseText = self.game.name
            
            // Swift has a bug where using unowned references can lead to swift_abortRetainUnowned errors.
            // Specifically, if you pause a game, open the save states menu, go back, return to menu, select a new game, then try to pause it, it will crash
            // As a dirty workaround, we just use a weak reference, and force unwrap it if needed
            
            let saveStateItem = PauseItem(image: UIImage(named: "SaveSaveState")!, text: NSLocalizedString("Save State", comment: ""), action: { [unowned self] _ in
                pauseViewController.presentSaveStateViewControllerWithMode(.Saving, delegate: self)
            })
            
            let loadStateItem = PauseItem(image: UIImage(named: "LoadSaveState")!, text: NSLocalizedString("Load State", comment: ""), action: { [unowned self] _ in
                pauseViewController.presentSaveStateViewControllerWithMode(.Loading, delegate: self)
            })
            
            let cheatCodesItem = PauseItem(image: UIImage(named: "SmallPause")!, text: NSLocalizedString("Cheat Codes", comment: ""), action: { [unowned self] _ in
                pauseViewController.presentCheatsViewController(delegate: self)
            })
            
            var sustainButtonsItem = PauseItem(image: UIImage(named: "SmallPause")!, text: NSLocalizedString("Sustain Buttons", comment: ""), action: { [unowned self] item in
                
                self.resetSustainedInputs(forGameController: gameController)
                
                if item.selected
                {
                    self.showSustainButtonView()
                    pauseViewController.dismiss()
                }
            })
            sustainButtonsItem.selected = self.sustainedInputs[ObjectIdentifier(gameController)]?.count > 0
            
            var fastForwardItem = PauseItem(image: UIImage(named: "FastForward")!, text: NSLocalizedString("Fast Forward", comment: ""), action: { [unowned self] item in
                self.emulatorCore.rate = item.selected ? self.emulatorCore.supportedRates.end : self.emulatorCore.supportedRates.start
            })
            fastForwardItem.selected = self.emulatorCore.rate == self.emulatorCore.supportedRates.start ? false : true
            
            pauseViewController.items = [saveStateItem, loadStateItem, cheatCodesItem, fastForwardItem, sustainButtonsItem]
            
            self.pauseViewController = pauseViewController
        }
    }
    
    @IBAction func unwindFromPauseViewController(segue: UIStoryboardSegue)
    {
        self.pauseViewController = nil
        self.pausingGameController = nil
        
        if self.resumeEmulation()
        {
            // Temporarily disable audioManager to prevent delayed audio bug when using 3D Touch Peek & Pop
            self.emulatorCore.audioManager.enabled = false
            
            // Re-enable after delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(0.1 * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
                self.emulatorCore.audioManager.enabled = true
            }
        }
    }
    
    //MARK: - 3D Touch -
    /// 3D Touch
    override func previewActionItems() -> [UIPreviewActionItem]
    {
        if let previewActionItems = self.overridePreviewActionItems
        {
            return previewActionItems
        }
        
        let presentingViewController = self.presentingViewController
        
        let launchGameAction = UIPreviewAction(title: NSLocalizedString("Launch \(self.game.name)", comment: ""), style: .Default) { (action, viewController) in
            // Delaying until next run loop prevents self from being dismissed immediately
            dispatch_async(dispatch_get_main_queue()) {
                presentingViewController?.presentViewController(viewController, animated: true, completion: nil)
            }
        }
        return [launchGameAction]
    }
}

//MARK: - Emulation -
/// Emulation
private extension EmulationViewController
{
    func pause(sender sender: AnyObject?)
    {
        self.performSegueWithIdentifier("pauseSegue", sender: sender)
    }
    
    func pauseEmulation() -> Bool
    {
        return self.emulatorCore.pauseEmulation()
    }
    
    func resumeEmulation() -> Bool
    {
        guard !self.choosingSustainedButtons && self.pauseViewController == nil else { return false }
        
        return self.emulatorCore.resumeEmulation()
    }
    
    func emulatorCoreDidUpdate(emulatorCore: EmulatorCore)
    {
        for semaphore in self.updateSemaphores
        {
            dispatch_semaphore_signal(semaphore.semaphore)
        }
    }
}

//MARK: - Controllers -
/// Controllers
private extension EmulationViewController
{
    @objc func updateControllers()
    {
        self.emulatorCore.removeAllGameControllers()
        
        if let index = Settings.localControllerPlayerIndex
        {
            self.controllerView.playerIndex = index
        }
        
        var controllers = [GameControllerProtocol]()
        controllers.append(self.controllerView)
        
        // We need to map each item as a GameControllerProtocol due to a Swift bug
        controllers.appendContentsOf(ExternalControllerManager.sharedManager.connectedControllers.map { $0 as GameControllerProtocol })
        
        for controller in controllers
        {
            if let index = controller.playerIndex
            {
                self.emulatorCore.setGameController(controller, atIndex: index)
                controller.addReceiver(self)
            }
            else
            {
                controller.removeReceiver(self)
            }
        }
        
        self.view.setNeedsLayout()
    }
}

//MARK: - Sustain Button -
private extension EmulationViewController
{
    func showSustainButtonView()
    {
        self.choosingSustainedButtons = true
        self.sustainButtonContentView.hidden = false
    }
    
    func hideSustainButtonView()
    {
        self.choosingSustainedButtons = false
        
        UIView.animateWithDuration(0.4, animations: { 
            self.sustainButtonContentView.alpha = 0.0
        }) { (finished) in
            self.sustainButtonContentView.hidden = true
            self.sustainButtonContentView.alpha = 1.0
        }
    }
    
    func resetSustainedInputs(forGameController gameController: GameControllerProtocol)
    {
        if let previousInputs = self.sustainedInputs[ObjectIdentifier(gameController)]
        {
            let receivers = gameController.receivers
            receivers.forEach { gameController.removeReceiver($0) }
            
            // Activate previousInputs without notifying anyone so we can then deactivate them
            // We do this because deactivating an already deactivated input has no effect
            previousInputs.forEach { gameController.activate($0) }
            
            receivers.forEach { gameController.addReceiver($0) }
            
            // Deactivate previously sustained inputs
            previousInputs.forEach { gameController.deactivate($0) }
        }
        
        self.sustainedInputs[ObjectIdentifier(gameController)] = []
    }
    
    func addSustainedInput(input: InputType, gameController: GameControllerProtocol)
    {
        var inputs = self.sustainedInputs[ObjectIdentifier(gameController)] ?? []
        
        guard !inputs.contains({ $0.isEqual(input) }) else { return }
        
        inputs.append(input)
        self.sustainedInputs[ObjectIdentifier(gameController)] = inputs
        
        let receivers = gameController.receivers
        receivers.forEach { gameController.removeReceiver($0) }
        
        // Causes input to be considered deactivated, so gameController won't send a subsequent message to observers when user actually deactivates
        // However, at this point the core still thinks it is activated, and is temporarily not a receiver, thus sustaining it
        gameController.deactivate(input)
        
        receivers.forEach { gameController.addReceiver($0) }
    }
    
    func reactivateSustainedInput(input: InputType, gameController: GameControllerProtocol)
    {
        // These MUST be performed serially, or else Bad Things Happen™ if multiple inputs are reactivated at once
        self.reactivateSustainInputsQueue.addOperationWithBlock {
            
            // The manual activations/deactivations here are hidden implementation details, so we won't notify ourselves about them
            gameController.removeReceiver(self)
            
            // Must deactivate first so core recognizes a secondary activation
            gameController.deactivate(input)
            
            let dispatchQueue = dispatch_queue_create("com.rileytestut.Delta.sustainButtonsQueue", DISPATCH_QUEUE_SERIAL)
            dispatch_async(dispatchQueue) {
                
                let semaphore = DispatchSemaphore(value: 0)
                self.updateSemaphores.insert(semaphore)
                
                // To ensure the emulator core recognizes us activating the input again, we need to wait at least two frames
                // Unfortunately we cannot init DispatchSemaphore with value less than 0
                // To compensate, we simply wait twice; once the first wait returns, we wait again
                dispatch_semaphore_wait(semaphore.semaphore, DISPATCH_TIME_FOREVER)
                dispatch_semaphore_wait(semaphore.semaphore, DISPATCH_TIME_FOREVER)
                
                // These MUST be performed serially, or else Bad Things Happen™ if multiple inputs are reactivated at once
                self.reactivateSustainInputsQueue.addOperationWithBlock {
                    
                    self.updateSemaphores.remove(semaphore)
                    
                    // Ensure we still are not a receiver (to prevent rare race conditions)
                    gameController.removeReceiver(self)
                    
                    gameController.activate(input)
                    
                    let receivers = gameController.receivers
                    receivers.forEach { gameController.removeReceiver($0) }
                    
                    // Causes input to be considered deactivated, so gameController won't send a subsequent message to observers when user actually deactivates
                    // However, at this point the core still thinks it is activated, and is temporarily not a receiver, thus sustaining it
                    gameController.deactivate(input)
                    
                    receivers.forEach { gameController.addReceiver($0) }
                }
                
                // More Bad Things Happen™ if we add self as observer before ALL reactivations have occurred (notable, infinite loops)
                self.reactivateSustainInputsQueue.waitUntilAllOperationsAreFinished()
                
                gameController.addReceiver(self)
                
            }
        }
    }
}

//MARK: - Save States
/// Save States
extension EmulationViewController: SaveStatesViewControllerDelegate
{
    func saveStatesViewControllerActiveEmulatorCore(saveStatesViewController: SaveStatesViewController) -> EmulatorCore
    {
        return self.emulatorCore
    }
    
    func saveStatesViewController(saveStatesViewController: SaveStatesViewController, updateSaveState saveState: SaveState)
    {
        guard let filepath = saveState.fileURL.path else { return }
        
        var updatingExistingSaveState = true
        
        self.emulatorCore.saveSaveState { temporarySaveState in
            do
            {
                if NSFileManager.defaultManager().fileExistsAtPath(filepath)
                {
                    try NSFileManager.defaultManager().replaceItemAtURL(saveState.fileURL, withItemAtURL: temporarySaveState.fileURL, backupItemName: nil, options: [], resultingItemURL: nil)
                }
                else
                {
                    try NSFileManager.defaultManager().moveItemAtURL(temporarySaveState.fileURL, toURL: saveState.fileURL)
                    
                    updatingExistingSaveState = false
                }
            }
            catch let error as NSError
            {
                print(error)
            }
        }
        
        if let outputImage = self.gameView.outputImage
        {
            let quartzImage = self.context.createCGImage(outputImage, fromRect: outputImage.extent)
            
            let image = UIImage(CGImage: quartzImage)
            UIImagePNGRepresentation(image)?.writeToURL(saveState.imageFileURL, atomically: true)
        }
        
        saveState.modifiedDate = NSDate()
        
        // Dismiss if updating an existing save state.
        // If creating a new one, don't dismiss.
        if updatingExistingSaveState
        {
            self.pauseViewController?.dismiss()
        }
    }
    
    func saveStatesViewController(saveStatesViewController: SaveStatesViewController, loadSaveState saveState: SaveStateType)
    {
        self.emulatorCore.loadSaveState(saveState)
        
        self.updateCheats()
        
        self.pauseViewController?.dismiss()
    }
}

//MARK: - Cheats
/// Cheats
extension EmulationViewController: CheatsViewControllerDelegate
{
    func cheatsViewControllerActiveEmulatorCore(saveStatesViewController: CheatsViewController) -> EmulatorCore
    {
        return self.emulatorCore
    }
    
    func cheatsViewController(cheatsViewController: CheatsViewController, didActivateCheat cheat: Cheat) throws
    {
        try self.emulatorCore.activateCheat(cheat)
    }
    
    func cheatsViewController(cheatsViewController: CheatsViewController, didDeactivateCheat cheat: Cheat)
    {
        self.emulatorCore.deactivateCheat(cheat)
    }
    
    private func updateCheats()
    {
        let backgroundContext = DatabaseManager.sharedManager.backgroundManagedObjectContext()
        backgroundContext.performBlockAndWait {
            
            let running = (self.emulatorCore.state == .Running)
            
            if running
            {
                // Core MUST be paused when activating cheats, or else race conditions could crash the core
                self.pauseEmulation()
            }
            
            let predicate = NSPredicate(format: "%K == %@", Cheat.Attributes.game.rawValue, self.emulatorCore.game as! Game)
            
            let cheats = Cheat.instancesWithPredicate(predicate, inManagedObjectContext: backgroundContext, type: Cheat.self)
            for cheat in cheats
            {
                if cheat.enabled
                {
                    do
                    {
                        try self.emulatorCore.activateCheat(cheat)
                    }
                    catch EmulatorCore.CheatError.invalid
                    {
                        print("Invalid cheat:", cheat.name, cheat.code)
                    }
                    catch let error as NSError
                    {
                        print("Unknown Cheat Error:", error, cheat.name, cheat.code)
                    }
                    
                }
                else
                {
                    self.emulatorCore.deactivateCheat(cheat)
                }
            }
            
            if running
            {
                self.resumeEmulation()
            }
            
        }
        
    }
}

//MARK: - App Lifecycle -
private extension EmulationViewController
{
    @objc func willResignActive(notification: NSNotification)
    {
        self.pauseEmulation()
    }
    
    @objc func didBecomeActive(notification: NSNotification)
    {
        self.resumeEmulation()
    }
}

//MARK: - <GameControllerReceiver> -
/// <GameControllerReceiver>
extension EmulationViewController: GameControllerReceiverProtocol
{
    func gameController(gameController: GameControllerProtocol, didActivateInput input: InputType)
    {        
        if gameController is ControllerView && UIDevice.currentDevice().supportsVibration
        {
            UIDevice.currentDevice().vibrate()
        }
        
        if let input = input as? ControllerInput
        {
            switch input
            {
            case ControllerInput.Menu:
                if self.choosingSustainedButtons { self.hideSustainButtonView() }
                self.pause(sender: gameController)
                
                // Return now, because Menu cannot be sustained
                return
            }
        }
        
        if self.choosingSustainedButtons
        {
            self.addSustainedInput(input, gameController: gameController)
            return
        }
        
        if let sustainedInputs = self.sustainedInputs[ObjectIdentifier(gameController)] where sustainedInputs.contains({ $0.isEqual(input) })
        {
            // Perform on next run loop
            dispatch_async(dispatch_get_main_queue()) {
                self.reactivateSustainedInput(input, gameController: gameController)
            }
            
            return
        }
    }
    
    func gameController(gameController: GameControllerProtocol, didDeactivateInput input: InputType)
    {
        guard let input = input as? ControllerInput else { return }
        
        print("Deactivated \(input)")
    }
}
