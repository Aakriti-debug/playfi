// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title PlayFi
 * @dev GameFi aggregator providing yield strategies via in-game assets
 * @author PlayFi Team
 */
contract PlayFi is ReentrancyGuard, Ownable, Pausable {
    
    // Structs
    struct GameAsset {
        address contractAddress;
        uint256 tokenId;
        address owner;
        uint256 stakedTimestamp;
        uint256 yieldRate; // Yield per second in basis points
        bool isStaked;
    }
    
    struct YieldStrategy {
        string name;
        uint256 baseYieldRate;
        uint256 bonusMultiplier;
        uint256 minimumStakePeriod;
        bool isActive;
    }
    
    // State variables
    mapping(bytes32 => GameAsset) public stakedAssets;
    mapping(address => uint256) public userRewards;
    mapping(address => bytes32[]) public userStakedAssets;
    mapping(uint256 => YieldStrategy) public yieldStrategies;
    
    IERC20 public rewardToken;
    uint256 public totalStakedAssets;
    uint256 public strategyCount;
    
    // Events
    event AssetStaked(address indexed user, address indexed nftContract, uint256 indexed tokenId, uint256 strategyId);
    event AssetUnstaked(address indexed user, address indexed nftContract, uint256 indexed tokenId, uint256 reward);
    event RewardsClaimed(address indexed user, uint256 amount);
    event StrategyAdded(uint256 indexed strategyId, string name, uint256 baseYieldRate);
    event StrategyUpdated(uint256 indexed strategyId, uint256 newYieldRate, uint256 newBonusMultiplier);
    
    // Modifiers
    modifier validStrategy(uint256 _strategyId) {
        require(_strategyId < strategyCount && yieldStrategies[_strategyId].isActive, "Invalid or inactive strategy");
        _;
    }
    
    constructor(address _rewardToken) Ownable(msg.sender) {
        rewardToken = IERC20(_rewardToken);
        
        // Initialize default yield strategy
        yieldStrategies[0] = YieldStrategy({
            name: "Basic Yield",
            baseYieldRate: 100, // 1% per day in basis points per second
            bonusMultiplier: 100, // 1x multiplier
            minimumStakePeriod: 1 days,
            isActive: true
        });
        strategyCount = 1;
    }
    
    /**
     * @dev Core Function 1: Stake in-game NFT assets to earn yield
     * @param _nftContract Address of the NFT contract
     * @param _tokenId Token ID of the NFT
     * @param _strategyId ID of the yield strategy to use
     */
    function stakeGameAsset(
        address _nftContract, 
        uint256 _tokenId, 
        uint256 _strategyId
    ) external nonReentrant whenNotPaused validStrategy(_strategyId) {
        require(_nftContract != address(0), "Invalid NFT contract");
        
        IERC721 nftContract = IERC721(_nftContract);
        require(nftContract.ownerOf(_tokenId) == msg.sender, "Not the owner of this NFT");
        require(nftContract.isApprovedForAll(msg.sender, address(this)) || 
                nftContract.getApproved(_tokenId) == address(this), "Contract not approved");
        
        bytes32 assetKey = keccak256(abi.encodePacked(_nftContract, _tokenId));
        require(!stakedAssets[assetKey].isStaked, "Asset already staked");
        
        // Transfer NFT to contract
        nftContract.transferFrom(msg.sender, address(this), _tokenId);
        
        // Create staked asset record
        YieldStrategy memory strategy = yieldStrategies[_strategyId];
        stakedAssets[assetKey] = GameAsset({
            contractAddress: _nftContract,
            tokenId: _tokenId,
            owner: msg.sender,
            stakedTimestamp: block.timestamp,
            yieldRate: strategy.baseYieldRate * strategy.bonusMultiplier / 100,
            isStaked: true
        });
        
        userStakedAssets[msg.sender].push(assetKey);
        totalStakedAssets++;
        
        emit AssetStaked(msg.sender, _nftContract, _tokenId, _strategyId);
    }
    
    /**
     * @dev Core Function 2: Unstake assets and claim accumulated rewards
     * @param _nftContract Address of the NFT contract
     * @param _tokenId Token ID of the NFT
     */
    function unstakeGameAsset(address _nftContract, uint256 _tokenId) external nonReentrant {
        bytes32 assetKey = keccak256(abi.encodePacked(_nftContract, _tokenId));
        GameAsset storage asset = stakedAssets[assetKey];
        
        require(asset.isStaked, "Asset not staked");
        require(asset.owner == msg.sender, "Not the owner of this staked asset");
        
        // Calculate rewards
        uint256 stakingDuration = block.timestamp - asset.stakedTimestamp;
        uint256 reward = calculateReward(asset.yieldRate, stakingDuration);
        
        // Update user rewards
        userRewards[msg.sender] += reward;
        
        // Return NFT to owner
        IERC721(_nftContract).transferFrom(address(this), msg.sender, _tokenId);
        
        // Remove from user's staked assets array
        _removeFromUserStakedAssets(msg.sender, assetKey);
        
        // Clear staked asset data
        delete stakedAssets[assetKey];
        totalStakedAssets--;
        
        emit AssetUnstaked(msg.sender, _nftContract, _tokenId, reward);
    }
    
    /**
     * @dev Core Function 3: Aggregate and optimize yield strategies across multiple games
     * @param _user Address of the user
     * @return totalYield Total potential yield across all strategies
     * @return optimalStrategy ID of the most profitable strategy
     * @return projectedRewards 30-day projected rewards
     */
    function aggregateYieldStrategies(address _user) external view returns (
        uint256 totalYield,
        uint256 optimalStrategy,
        uint256 projectedRewards
    ) {
        bytes32[] memory userAssets = userStakedAssets[_user];
        uint256 maxYieldRate = 0;
        uint256 currentRewards = userRewards[_user];
        
        // Calculate total current yield from staked assets
        for (uint256 i = 0; i < userAssets.length; i++) {
            GameAsset memory asset = stakedAssets[userAssets[i]];
            if (asset.isStaked) {
                uint256 stakingDuration = block.timestamp - asset.stakedTimestamp;
                totalYield += calculateReward(asset.yieldRate, stakingDuration);
                
                if (asset.yieldRate > maxYieldRate) {
                    maxYieldRate = asset.yieldRate;
                }
            }
        }
        
        // Find optimal strategy
        for (uint256 j = 0; j < strategyCount; j++) {
            YieldStrategy memory strategy = yieldStrategies[j];
            if (strategy.isActive) {
                uint256 strategyYield = strategy.baseYieldRate * strategy.bonusMultiplier / 100;
                if (strategyYield > maxYieldRate) {
                    maxYieldRate = strategyYield;
                    optimalStrategy = j;
                }
            }
        }
        
        totalYield += currentRewards;
        
        // Project 30-day rewards based on current average yield
        if (userAssets.length > 0) {
            uint256 avgYieldRate = maxYieldRate > 0 ? maxYieldRate : 100;
            projectedRewards = calculateReward(avgYieldRate, 30 days) * userAssets.length;
        }
        
        return (totalYield, optimalStrategy, projectedRewards);
    }
    
    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external nonReentrant {
        uint256 reward = userRewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        
        userRewards[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, reward), "Reward transfer failed");
        
        emit RewardsClaimed(msg.sender, reward);
    }
    
    /**
     * @dev Add new yield strategy (only owner)
     */
    function addYieldStrategy(
        string memory _name,
        uint256 _baseYieldRate,
        uint256 _bonusMultiplier,
        uint256 _minimumStakePeriod
    ) external onlyOwner {
        yieldStrategies[strategyCount] = YieldStrategy({
            name: _name,
            baseYieldRate: _baseYieldRate,
            bonusMultiplier: _bonusMultiplier,
            minimumStakePeriod: _minimumStakePeriod,
            isActive: true
        });
        
        emit StrategyAdded(strategyCount, _name, _baseYieldRate);
        strategyCount++;
    }
    
    /**
     * @dev Update existing yield strategy (only owner)
     */
    function updateYieldStrategy(
        uint256 _strategyId,
        uint256 _baseYieldRate,
        uint256 _bonusMultiplier
    ) external onlyOwner validStrategy(_strategyId) {
        YieldStrategy storage strategy = yieldStrategies[_strategyId];
        strategy.baseYieldRate = _baseYieldRate;
        strategy.bonusMultiplier = _bonusMultiplier;
        
        emit StrategyUpdated(_strategyId, _baseYieldRate, _bonusMultiplier);
    }
    
    /**
     * @dev Calculate reward based on yield rate and duration
     */
    function calculateReward(uint256 _yieldRate, uint256 _duration) public pure returns (uint256) {
        // Yield rate is in basis points per second (10000 = 100%)
        return (_yieldRate * _duration) / 10000;
    }
    
    /**
     * @dev Get user's staked assets
     */
    function getUserStakedAssets(address _user) external view returns (bytes32[] memory) {
        return userStakedAssets[_user];
    }
    
    /**
     * @dev Get detailed asset information
     */
    function getAssetDetails(bytes32 _assetKey) external view returns (GameAsset memory) {
        return stakedAssets[_assetKey];
    }
    
    /**
     * @dev Emergency withdraw function (only owner)
     */
    function emergencyWithdraw(address _nftContract, uint256 _tokenId) external onlyOwner {
        IERC721(_nftContract).transferFrom(address(this), owner(), _tokenId);
    }
    
    /**
     * @dev Pause/unpause contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Internal function to remove asset from user's staked assets array
     */
    function _removeFromUserStakedAssets(address _user, bytes32 _assetKey) internal {
        bytes32[] storage assets = userStakedAssets[_user];
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == _assetKey) {
                assets[i] = assets[assets.length - 1];
                assets.pop();
                break;
            }
        }
    }
}
