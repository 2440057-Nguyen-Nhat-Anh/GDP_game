/**
* Name: main
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model main

global {
	// Exploration parameter for road level
	int initial_road_level <- 4;  // Parameter to explore different road levels
	
	float gdp_current <- 0.0;
    float gdp_previous <- 0.0;
    float gdp_growth_rate <- 0.0;
    
    // GDP flow tracking (cumulative)
    float total_wages_paid <- 0.0;  // Cumulative wages paid by factories
    float total_govt_spending <- 0.0;  // Cumulative government spending on infrastructure
    float total_private_spending <- 0.0;  // Cumulative private investment spending
    
    list<float> gdp_history <- [];
    // =================================================================
    // ECONOMIC PARAMETERS
    // =================================================================
    float factory_tax_rate <- 0.15;  // 15% tax on factory revenue
    float salary_per_hour <- 12.0;    // Base hourly wage for workers
    float total_goods_produced update: building where (each.type = "factory") sum_of (each.goods); // Total amount of goods currently available in all factories

    // =================================================================
    // SPATIAL DATA
    // =================================================================
    file shapefile_buildings <- file("../includes/buildings.shp");
    file shapefile_roads <- file("../includes/roads.shp");
    
    geometry shape <- envelope(shapefile_roads);
    graph road_network;  // Road graph for pathfinding
    
    // =================================================================
    // UI INTERACTION STATE
    // =================================================================
    road hover_road <- nil;      // Currently hovered road
    road selected_road <- nil;   // Currently selected road for upgrade
    building hover_building <- nil;  // Currently hovered building
    
    // Two-step road upgrade selection state
    bool waiting_for_factory_selection <- false;  // Are we in factory selection mode?
    building selected_factory <- nil;              // Factory selected for providing materials
    
    // =================================================================
    // PATHFINDING WEIGHTS
    // =================================================================
    map<road, float> new_weight;  // Updated each step: time-based routing (perimeter / speed_rate)

    // =================================================================
    // CITY FINANCES
    // =================================================================
    float city_budget <- 400000.0;  // Government budget from taxes (starts with $400k)
    float private_investment <- 1600000.0;  // Private investment from citizen bank deposits (starts with $1.6M)
    float total_budget update: city_budget + private_investment;  // Combined budget for road upgrades
    float total_money_inhabitants update: inhabitant sum_of (each.money);  // Total wealth of all inhabitants
    float total_factory_revenue update: building where (each.type = "factory") sum_of (each.total_revenue);  // Sum of all factory revenues
    
    float daily_material_cost <- 500000.0;  // Daily operating cost for factories
        
    // =================================================================
    // TIME CONTROL
    // =================================================================
    float step <- 1#mn;  // Each simulation step = 1 minute
    date starting_date <- date([2024, 1, 1, 7, 0, 0]);  // Start at 7 AM on Jan 1, 2024
    int current_hour update: current_date.hour;  // Track current hour for schedules
    
    // =================================================================
    // DYNAMIC PATHFINDING WEIGHTS
    // =================================================================
    reflex update_speed {
		// Calculate time-based routing weights for each road
		// Weight = travel time = distance / speed
		new_weight <- road as_map (each::(each.shape.perimeter / each.speed_rate));
    }
    
    reflex calculate_daily_gdp when: (current_date.hour = 23 and current_date.minute = 59) {
		gdp_previous <- gdp_current;
		
		// GDP = Sum of all economic flows (wages paid + government spending + private investment)
		gdp_current <- total_wages_paid + total_govt_spending + total_private_spending;
		
		if (gdp_previous > 0) {
			gdp_growth_rate <- ((gdp_current - gdp_previous) / gdp_previous) * 100;
		}
		
		add gdp_current to: gdp_history;
		
		write "📊 GDP Report " + string(current_date, "dd/MM") + ": $" + string(gdp_current, "#.##") + " [Wages: $" + string(total_wages_paid, "#") + " | Gov: $" + string(total_govt_spending, "#") + " | Private: $" + string(total_private_spending, "#") + "]";
	}
		    
    // =================================================================
    // CITY INITIALIZATION
    // =================================================================
    init {
        // Load spatial data
        create road from: split_lines(shapefile_roads);
        road_network <- as_edge_graph(road);  // Build graph for pathfinding

        create building from: shapefile_buildings with: (height: int(read("HEIGHT")));
        
        // Assign building types
        // Pick 8 largest buildings as factories
        list<building> sorted_buildings <- (building where (each.shape.area > 9000)) sort_by (-each.shape.area);
        ask 8 among sorted_buildings { 	
            type <- "factory"; 
        }
        
        // Pick buildings near roads for banks and markets
        list<building> frontage <- building where (each.type = nil and each distance_to (road closest_to each) < 15.0);
        ask 5 among frontage { type <- "bank"; }
        ask 10 among frontage { type <- "market"; }
        
        // Remaining buildings are homes
        ask building where (each.type = nil) { 
            type <- "home"; 
            capacity <- 4;  // Each home can house 4 residents
        }
        
        // Create 1000 inhabitants
        create inhabitant number: 1000 {
            // Assign home (prefer homes with space)
            home <- one_of(building where (each.type = "home" and length(each.residents) < each.capacity));
            if (home != nil) {
                location <- any_location_in(home);
                add self to: home.residents;
            } else {
                home <- one_of(building where (each.type = "home"));
                location <- any_location_in(home);
            }
            // Assign workplace and initial money
            workplace <- one_of(building where (each.type = "factory"));
            money <- rnd(100.0, 500.0);  // Random starting wealth $100-$500
        }
        
        // Give factories initial revenue to cover ~30 days of operations
        ask building where (each.type = "factory") {
            int num_workers <- length(inhabitant where (each.workplace = self));
            // Varied initial capital: 15-30 days of payroll (material costs removed)
            int days_capital <- rnd(15, 30);
            float initial_capital <- (num_workers * 9 * salary_per_hour * days_capital);
            total_revenue <- initial_capital;
            
            // Initial goods inventory: 200k-400k units per factory (enough for immediate road upgrades)
            goods <- rnd(200000.0, 400000.0);
            
            write "Factory " + name + " initialized with " + num_workers + " workers, $" + initial_capital + " capital (" + days_capital + " days), and " + goods + " goods";
        }
    }
}

// =================================================================
// BUILDING SPECIES - Factories, Banks, Markets, Homes
// =================================================================
species building {
	// Building properties
	int level <- 1;  // Upgrade level (affects capacity and costs)
    float height;    // Visual height from shapefile
    string type;     // "factory", "bank", "market", or "home"
    int capacity;    // Max residents (homes) or workers (factories)
    list<inhabitant> residents;  // List of inhabitants living here
    float total_revenue <- 0.0;  // Revenue generated (factories only)
    float goods <- 0.0;  // Goods inventory (factories only) - produced by workers
    
    // Debt tracking for factories
    int days_without_payment <- 0;  // Days factory couldn't pay workers
    bool in_debt <- false;  // Is factory in debt? (15+ days unpaid)
    
    // Upgrade mechanics
    bool is_upgrade <- false;  // Currently upgrading?
    date upgrade_time;         // When upgrade completes
    float upgrade_cost <- (shape.area * 500 * level);  // Cost scales with size and level
    
    action start_upgrade {
    	if (type = "factory" and !is_upgrade and city_budget >= upgrade_cost) {
    		city_budget <- city_budget - upgrade_cost;
    		is_upgrade <- true;
    		upgrade_time <- current_date + 5#day;
    		write "Factory " + name + " is upgrading to level " + (level + 1);
    	} else {
    		write "You need $" + upgrade_cost + " to upgrade factory " + name;
    	}
    }
    
    reflex check_upgrade_finished when: is_upgrade {
        if (current_date >= upgrade_time) {
            is_upgrade <- false;
            level <- level + 1;
            capacity <- capacity + 5; 
            write "Factory " + name + " upgraded to level " + level + ". Capacity increased!";
        }
    }
    
    reflex pay_taxes when: type = "factory" and current_date.hour = 0 and current_date.minute = 0 {
        float tax_amount <- total_revenue * factory_tax_rate;
        city_budget <- city_budget + tax_amount;
        total_revenue <- total_revenue - tax_amount;
    }
    
    // Material cost deduction removed - no longer deducting from factory revenue
    // reflex operate_factory when: type = "factory" and current_date.hour = 23 and current_date.minute = 0 {
    //     total_revenue <- total_revenue - daily_material_cost;
    //     if (total_revenue < 0) { 
    //     	total_revenue <- 0.0;
    //     }
	// 	write "Factory " + name + " after deducting material costs: $" + daily_material_cost;
    // }
    
    // Daily payroll for factory workers
    reflex pay_workers when: type = "factory" and current_date.hour = 17 and current_date.minute = 0 {
        // Count workers assigned to this factory
        int num_workers <- length(inhabitant where (each.workplace = self));
        
        // Calculate daily payroll (9 hours * $12/hour base salary)
        float daily_payroll <- num_workers * 9 * salary_per_hour * (1 + (level - 1) * 0.5);
        
        // Check if factory can pay
        if (total_revenue >= daily_payroll) {
            // Pay all workers
            ask inhabitant where (each.workplace = self) {
                float daily_salary <- 9 * salary_per_hour * (1 + (myself.level - 1) * 0.5);
                money <- money + daily_salary;
            }
            total_revenue <- total_revenue - daily_payroll;
            total_wages_paid <- total_wages_paid + daily_payroll;  // Track GDP flow
            days_without_payment <- 0;  // Reset counter
            in_debt <- false;
        } else {
            // Can't pay - increment debt counter
            days_without_payment <- days_without_payment + 1;
            if (days_without_payment >= 15) {
                in_debt <- true;
                write "⚠️ Factory " + name + " is in debt! " + days_without_payment + " days without payment!";
            }
        }
    }

    aspect default {
        rgb b_color <- #gray;
        
        if (in_debt) {
            b_color <- #red;  // Factory in debt (15+ days unpaid)
        } else if (is_upgrade) {
        	b_color <- #brown;
        } else {          
            switch type {
                match "bank" { b_color <- #yellow; }
                match "factory" { b_color <- #orange; }
                match "market" { b_color <- #cyan; }
            }
        }
        
        if (self = hover_building) { 
        	b_color <- #blue;
        }
        
        draw shape color: b_color border: #black;
        
	    if (type = "factory" and level > 1) {
	            draw "LVL " + level at: location + {0,0,height+2} color: #white size: 10;
        }
    }
    
}

// =================================================================
// ROAD SPECIES - Traffic simulation and upgrade mechanics
// =================================================================
species road {
	// Road properties
	int level <- initial_road_level;  // Upgrade level set by exploration parameter
    float capacity <- (1 + shape.perimeter / 30) * 2^(level - 1);  // Traffic capacity doubles with each level (L1:1x, L2:2x, L3:4x, L4:8x)
    int nb_drivers <- 0 update: length(inhabitant where (each.current_road = self));  // Count inhabitants currently on this road
    float speed_rate <- 1.0 update: exp(-nb_drivers / capacity) min: 0.2;  // Speed degrades exponentially with congestion (min 0.2 = 1 km/h)
    
    // Upgrade mechanics
    float upgrade_cost <- shape.perimeter * 200 * level;  // Cost: $200 per meter * level
    float material_cost <- shape.perimeter * 500 * level;  // Material units needed: 500 units per meter * level (93% labor cost = 7% profit margin)
    bool is_under_construction <- false;  // Currently being upgraded?
    bool waiting_to_upgrade <- false;  // Waiting for road to clear before starting upgrade
    date construction_end_time;  // When construction finishes
    
    action start_upgrade {
    	if (!is_under_construction and !waiting_to_upgrade) {
    		// Check if total budget (government + private) is sufficient
    		if (total_budget >= upgrade_cost) {
    			write "💰 Budget OK ($" + upgrade_cost + "). Material needed: " + material_cost + " units. Select a factory...";
    			return true;  // Ready for factory selection
    		} else {
    			write "❌ Insufficient budget! Need $" + upgrade_cost + " (have $" + total_budget + ")";
    			return false;
    		}
    	} else if (waiting_to_upgrade) {
    		write "⏳ Road upgrade already pending - waiting for drivers to leave (" + nb_drivers + " remaining)";
    		return false;
    	} else {
    		write "🚧 Road is already under construction";
    		return false;
    	}
    }
        action confirm_upgrade_with_factory(building factory) {
    	// Validate factory has enough materials
    	if (factory.goods < material_cost) {
    		write "❌ Factory " + factory.name + " only has " + factory.goods + " goods (need " + material_cost + ")";
    		return;
    	}
    	
    	// Calculate budget split: 20% government, 80% private investment
    	float govt_share <- upgrade_cost * 0.20;
    	float private_share <- upgrade_cost * 0.80;
    	
    	// Check if budgets can cover costs (with fallback)
    	float govt_payment <- min(govt_share, city_budget);
    	float private_payment <- min(private_share, private_investment);
    	
    	// If one can't cover, use the other
    	float total_available <- govt_payment + private_payment;
    	if (total_available < upgrade_cost) {
    		write "❌ Insufficient total budget! Need $" + upgrade_cost + " (have $" + total_available + ")";
    		return;
    	}
    	
    	// Adjust payments if one is short
    	if (govt_payment < govt_share) {
    		private_payment <- upgrade_cost - govt_payment;
    	} else if (private_payment < private_share) {
    		govt_payment <- upgrade_cost - private_payment;
    	}
    	
    	// Start construction immediately (no waiting for road to clear)
    	float factory_profit <- upgrade_cost * 0.07;  // 7% profit margin
    	float profit_tax <- factory_profit * 0.20;  // 20% tax on profit
    	float factory_net_revenue <- upgrade_cost - profit_tax;  // Factory gets 98.6% of payment
    	
    	city_budget <- city_budget - govt_payment + profit_tax;  // Deduct govt share, add profit tax
    	private_investment <- private_investment - private_payment;  // Deduct private share
    	
    	// Track GDP flows (government + private spending)
    	total_govt_spending <- total_govt_spending + govt_payment;
    	total_private_spending <- total_private_spending + private_payment;
    	
    	ask factory {
    		// Goods are NOT deducted - they accumulate to show economic production
    		// goods <- goods - myself.material_cost;  // REMOVED: goods now accumulate
    		total_revenue <- total_revenue + factory_net_revenue;  // Factory gets net payment
    	}
    	is_under_construction <- true;
    	construction_end_time <- current_date + 1#day;
    	write "🚧 Road upgrade started! Govt: $" + govt_payment + " + Private: $" + private_payment + ". Factory " + factory.name + " paid $" + factory_net_revenue;
    }
        // Monitor waiting roads and start construction when clear
    reflex start_upgrade_when_clear when: waiting_to_upgrade {
        if (nb_drivers = 0) {
            // Road is now clear - deduct cost and begin construction
            city_budget <- city_budget - upgrade_cost;
            waiting_to_upgrade <- false;
            is_under_construction <- true;
            construction_end_time <- current_date + 1#day;
            write "✅ Road cleared! Construction starting now. Expected completion: " + string(construction_end_time);
        }
    }
    
    reflex check_construction_finished when: is_under_construction {
        if (current_date >= construction_end_time) {
            is_under_construction <- false;
            level <- level + 1;
            capacity <- (1 + shape.perimeter / 30) * 2^(level - 1);
            write "🎉 Road upgrade complete! New level: " + level + " | Capacity increased!";
            is_under_construction <- false;
        }
    }
    
    aspect default {
	    rgb road_color;
	    
	    if (is_under_construction) {
	        road_color <- #brown;  // Construction in progress
	    } else if (waiting_to_upgrade) {
	        road_color <- #orange;  // Waiting for drivers to clear
	    } else if (self = selected_road) { 
	        road_color <- #purple;
	    } else if (self = hover_road) {
	        road_color <- #blue;
	    } else {
	        float traffic_ratio <- (1 - (speed_rate / level)); 
	        road_color <- blend(#red, #pink, max(0.0, min(1.0, traffic_ratio)));
	    }
	    
	    float display_width <- (1 + level + 2 * (1 - min(1.0, speed_rate/level)));
	    draw (shape buffer display_width) color: road_color;
	    
	    if (level > 1 and !is_under_construction) {
	        draw "L" + level at: location color: #white size: 8;
	    }
	}
}

// =================================================================
// INHABITANT SPECIES - Citizens with daily schedules and economic activity
// =================================================================
species inhabitant skills: [moving] {
    // Movement and locations
    point target;         // Current destination (nil when not moving)
    building home;        // Assigned home building
    building workplace;   // Assigned factory
    road current_road;    // Current road the inhabitant is on (nil when not on a road)
    
    // State tracking
    string status <- "resting";  // "resting", "working", or "moving_free"
    float money;                  // Current wealth
    float speed <- 5 #km/#h;     // Movement speed (dynamically updated based on road conditions)
    int time_buffer <- int(gauss(30, 15)) min: 0 max: 60;  // Minutes before 8 AM to start commute (gaussian: mean 30, std 15)

    // Movement reflex - uses time-based pathfinding
    reflex move when: (target != nil) {
        // Find the closest road to update current_road tracking
        road closest_road <- road closest_to self;
        
        // Update current_road if we're close enough to a road (within 5 meters)
        if (closest_road != nil and (self distance_to closest_road) < 5.0) {
            // If switching roads, update the mapping
            if (current_road != closest_road) {
                current_road <- closest_road;
            }
            // Dynamically adjust speed based on road conditions
            if (current_road.is_under_construction) {
                // Construction zones: fixed at half of minimum speed (0.5 km/h)
                speed <- 0.5 #km/#h;
            } else {
                // Normal traffic-based speed
                speed <- (5 #km/#h) * current_road.speed_rate;
            }
        } else {
            // Not on any road - use default speed
            current_road <- nil;
            speed <- 5 #km/#h;
        }
        
        // Navigate to target using road network with traffic-aware routing
        do goto target: target on: road_network move_weights: new_weight;
        
        // Clear target and current_road when arrived
        if (location = target) { 
            target <- nil;
            current_road <- nil;
        }
    }
    
    // Economic activity - produce goods while at work
    reflex produce_goods when: status = "working" and (current_hour >= 8 and current_hour < 17) {
        if (location overlaps workplace.shape) {
	        // Worker produces goods for the factory
	        ask workplace {
	            goods <- goods + 1.0;  // Each worker produces 1 unit of goods per minute
	        }
        }
    }
    
    // Bank visit - pay taxes and make investments
    reflex visit_bank when: status = "moving_free" {
        list<building> banks <- building where (each.type = "bank");
        loop b over: banks {
            if (location overlaps b.shape and money > 0) {
                // 15% as income tax to government
                float tax_amount <- money * 0.15;
                city_budget <- city_budget + tax_amount;
                
                // 80% as private investment and personal consumption
                float investment_amount <- money * 0.80;
                private_investment <- private_investment + investment_amount;
                
                // Keep remaining 5%
                money <- money * 0.05;
                break;
            }
        }
    }
    
    // Daily schedule - work, rest, and free time
    reflex schedule {
        int current_minutes <- current_date.hour * 60 + current_date.minute;
        int work_departure_time <- 7 * 60 + 30 + time_buffer;  // 7:30 AM + individual buffer
        int work_end_time <- 17 * 60 + time_buffer;  // 5:00 PM + individual buffer
        
        // WORK COMMUTE: Start at 7:30 AM + buffer
        if (current_minutes >= work_departure_time and current_minutes < work_end_time and status != "working") {
            // Go to workplace unless it's being upgraded
            if (!workplace.is_upgrade) {            		
                target <- any_location_in(workplace);
                status <- "working";
            } else {
                // If workplace upgrading, visit market or bank instead
                building destination <- one_of(building where (each.type = "market" or each.type = "bank"));
                if (destination != nil) {
                    target <- any_location_in(destination);
                    status <- "moving_free";
                }
            }
        // LEAVE WORK: At 4:45 PM + buffer
        } else if (current_minutes >= work_end_time and status = "working") {
            building destination <- one_of(building where (each.type = "market" or each.type = "bank"));
                    if (destination != nil) {
                        target <- any_location_in(destination);
                        status <- "moving_free";
                    }
                    if (location = destination) {
                    	destination <- nil;
                    }
        // NIGHT: 10 PM - 6 AM
        } else if (current_hour >= 22 or current_hour < 6) {
            if (status != "resting") {
                target <- any_location_in(home);
                status <- "resting";
            }
        // FREE TIME: 6 AM until work departure, and after work until 10 PM
        } else if ((current_hour >= 6 and current_minutes < work_departure_time) or (current_minutes >= work_end_time and current_hour < 22)) {
            if (target = nil and status != "moving_free") {
                float r <- rnd(0.0, 1.0);
                if (r < 0.2) {  // 20% chance to visit market/bank during free time
                    building target_b <- one_of(building where (each.type = "market" or each.type = "bank"));
                    if (target_b != nil) {
                        target <- any_location_in(target_b);
                        status <- "moving_free";
                    }
                }
            }
        }
    }
        
    aspect default {
        draw circle(5) color: #lightgreen;
    }
}

experiment project type: gui {
    parameter "Initial Road Level" var: initial_road_level min: 1 max: 10 category: "Infrastructure";
    parameter "Factory Tax Rate" var: factory_tax_rate category: "Policy";
    parameter "Daily Material Cost" var: daily_material_cost min: 0.0 max: 5000000.0;
    
    output {
        display map type: 3d axes: false background: #black {
            species building aspect: default;
            species road aspect: default;           
            species inhabitant aspect: default;
            
            event mouse_down {
				point m_pos <- #user_location;
				
				ask world {
					// Check if we're in factory selection mode
					if (waiting_for_factory_selection and selected_road != nil) {
						// User must click a factory
						building b <- building closest_to m_pos;
						if (b != nil and b.type = "factory" and (b distance_to m_pos < 10.0)) {
							// Valid factory clicked - confirm upgrade
							selected_factory <- b;
							ask selected_road {
								do confirm_upgrade_with_factory(myself.selected_factory);
							}
							// Reset selection state
							waiting_for_factory_selection <- false;
							selected_road <- nil;
							selected_factory <- nil;
						} else {
							// Clicked somewhere else - cancel sequence
							write "❌ Road upgrade cancelled. Click a road to start again.";
							selected_road <- nil;
							waiting_for_factory_selection <- false;
						}
					} else {
						// Normal mode - handle road and building clicks
						road r <- road closest_to m_pos;
						if (r != nil and (r distance_to m_pos < 15.0)) {
							selected_road <- r;
							bool can_proceed <- false;
							ask r {
								can_proceed <- start_upgrade();
							}
							if (can_proceed) {
								waiting_for_factory_selection <- true;
								write "🏭 Now select a factory to provide materials for this road upgrade...";
							} else {
								selected_road <- nil;
							}
						} else {
							selected_road <- nil;
						}
						
						building b <- building closest_to m_pos;
						if (b != nil and (b distance_to m_pos < 10.0) and b.type = "factory") {
							hover_building <- b;
							ask b {
								do start_upgrade;
							}
						} else {
							hover_building <- nil;
						}
					}
				}
			}
			
			event mouse_move {
                point m_pos <- #user_location;
                
                ask world {
//                	ask road {
//                		is_hovered <- false;
//                	}
                    road r <- road closest_to m_pos;
                    if (r != nil and (r distance_to m_pos < 15.0)) {
                        hover_road <- r;
//                        r.is_hovered <- true;
                    } else {
                        hover_road <- nil;
                    }
                    
                    building b <- building closest_to m_pos;
                    if (b != nil and (b distance_to m_pos < 10.0) and b.type = "factory") {
                    	hover_building <- b;
                    } else {
                    	hover_building <- nil;
                    }
                }
            }
            
            overlay position: {20#px, 20#px} size: {280#px, 470#px} background: #gray transparency: 0.2 border: #white {
			    float margin <- 20#px;
			    float y <- 30#px;
			
			    draw "CITY DASHBOARD" at: {margin, y} color: #white font: font("Arial", 18, #bold);
			    y <- y + 10#px;
			    draw line([{margin, y}, {260#px, y}]) color: #gray;
			    
			    y <- y + 30#px;
			    draw string(current_date, "dd/MM/yyyy") at: {margin, y} color: #lightgray font: font("Arial", 12);
			    draw string(current_date, "HH:mm") at: {200#px, y} color: #cyan font: font("Arial", 14, #bold);
			    
			    y <- y + 30#px;
			    draw "Government Budget: $" + string(city_budget, "#.##") at: {margin, y} color: #springgreen font: font("Arial", 10);
			    
			    y <- y + 20#px;
			    draw "Private Investment: $" + string(private_investment, "#.##") at: {margin, y} color: #gold font: font("Arial", 10);
			    
			    y <- y + 20#px;
			    draw "Total Budget: $" + string(total_budget, "#.##") at: {margin, y} color: #white font: font("Arial", 11, #bold);
			    
			    y <- y + 30#px;
			    draw "FACILITY TYPES" at: {margin, y} color: #cyan font: font("Arial", 11, #bold);
			    y <- y + 5#px;
			    draw line([{margin, y}, {150#px, y}]) color: #cyan;
			    
			    y <- y + 25#px;
			    draw rectangle(12#px, 12#px) at: {margin + 6#px, y} color: #orange; 
			    draw "Factory" at: {margin + 25#px, y + 5#px} color: #white font: font("Arial", 11);
			    
			    draw rectangle(12#px, 12#px) at: {margin + 120#px, y} color: #yellow; 
			    draw "Bank" at: {margin + 140#px, y + 5#px} color: #white font: font("Arial", 11);
			    
			    y <- y + 25#px;
			    draw rectangle(12#px, 12#px) at: {margin + 6#px, y} color: #cyan; 
			    draw "Market" at: {margin + 25#px, y + 5#px} color: #white font: font("Arial", 11);
			    
			    draw rectangle(12#px, 12#px) at: {margin + 120#px, y} color: #gray; 
			    draw "Home" at: {margin + 140#px, y + 5#px} color: #white font: font("Arial", 11);
			
				y <- y + 25#px;
				draw "City GDP: $" + string(world.gdp_current, "#.##") at: {margin, y} color: #cyan font: font("Arial", 11, #bold);
				
				y <- y + 18#px;
				rgb growth_color <- (world.gdp_growth_rate >= 0) ? #springgreen : #red;
				draw "Growth: " + string(world.gdp_growth_rate, "#.#") + "%" at: {margin, y} color: growth_color font: font("Arial", 10);
				
				y <- y + 25#px;
				draw "Total Goods: " + string(world.total_goods_produced, "#") + " units" at: {margin, y} color: #springgreen font: font("Arial", 11, #bold);
			
			    y <- y + 50#px;
			    
			    if (hover_building != nil or hover_road != nil) {
			        draw rectangle(240#px, 150#px) at: {140#px, y + 40#px} color: rgb(50, 50, 50, 150) border: #cyan;
			        
			        if (hover_building != nil) {
					    draw "BUILDING: " + hover_building.type at: {margin + 10#px, y} color: #cyan font: font("Arial", 12, #bold);
					    
					    draw "Level: " + hover_building.level at: {margin + 10#px, y + 20#px} color: #white font: font("Arial", 10);
					    draw "Area: " + string(hover_building.shape.area, "#") + " m²" at: {margin + 10#px, y + 40#px} color: #white font: font("Arial", 10);
					    
					    if (hover_building.type = "factory") {
				        draw "Budget: $" + string(hover_building.total_revenue, "#.##") at: {margin + 10#px, y + 60#px} color: #yellow font: font("Arial", 10);
				        draw "Materials: " + string(hover_building.goods, "#") + " units" at: {margin + 10#px, y + 80#px} color: #springgreen font: font("Arial", 10);
					    }
					    
					    if (hover_building.is_upgrade) {
					        draw "STATUS: UPGRADING..." at: {margin + 10#px, y + 100#px} color: #springgreen font: font("Arial", 11, #italic);
					    } else {
					        draw "Next Upgrade: $" + string(hover_building.upgrade_cost, "#.##") at: {margin + 10#px, y + 100#px} color: #cyan font: font("Arial", 10, #bold);
					    }
					} else if (hover_road != nil) {
			            draw "ROAD SECTOR" at: {margin + 10#px, y + 20#px} color: #cyan font: font("Arial", 12, #bold);
			            draw "Current Level: " + hover_road.level at: {margin + 10#px, y + 45#px} color: #white;
			            
			            if (hover_road.is_under_construction) {
			                draw "STATUS: WORK IN PROGRESS" at: {margin + 10#px, y + 70#px} color: #springgreen;
			            } else {
			                draw "Upgrade: $" + string(hover_road.upgrade_cost, "#.##") at: {margin + 10#px, y + 70#px} color: #cyan;
			            }
			        }
			    } else {
			        draw "Select a building or road" at: {margin, y + 20#px} color: #gray font: font("Arial", 11, #italic);
			    }
			}
        }
    	
    	display Economic_Analysis {
		    chart "City GDP Trend" type: series background: #black color: #white {
		        data "Gross Domestic Product" value: gdp_current color: #cyan;
		    }
		}
		
		display Production_Analysis {
	        chart "Factory Goods Inventory" type: series background: #black color: #white {
	            data "Total Goods in City" value: total_goods_produced color: #springgreen;
	        }
	    }
    }
}

// =================================================================
// EXPLORATION EXPERIMENT - Test goods production with different road levels
// =================================================================
experiment explore_road_levels type: batch repeat: 3 keep_seed: true until: (cycle >= 1440) {
    // Explore road levels from 1 to 5
    parameter "Initial Road Level" var: initial_road_level among: [1, 2, 3, 4, 5];
    
    // Track total goods produced at end of 1 day (1440 minutes)
    reflex save_results {
        ask simulations {
            save [initial_road_level, total_goods_produced, gdp_current, total_wages_paid] 
                to: "exploration_results.csv" rewrite: false;
        }
    }
    
    // Display results
    permanent {
        display "Goods Production by Road Level" {
            chart "Total Goods Produced After 1 Day" type: series background: #white {
                data "Road Level 1" value: simulations where (each.initial_road_level = 1) collect each.total_goods_produced color: #red;
                data "Road Level 2" value: simulations where (each.initial_road_level = 2) collect each.total_goods_produced color: #orange;
                data "Road Level 3" value: simulations where (each.initial_road_level = 3) collect each.total_goods_produced color: #yellow;
                data "Road Level 4" value: simulations where (each.initial_road_level = 4) collect each.total_goods_produced color: #green;
                data "Road Level 5" value: simulations where (each.initial_road_level = 5) collect each.total_goods_produced color: #blue;
            }
        }
        
        display "GDP by Road Level" {
            chart "GDP After 1 Day" type: series background: #white {
                data "Road Level 1" value: simulations where (each.initial_road_level = 1) collect each.gdp_current color: #red;
                data "Road Level 2" value: simulations where (each.initial_road_level = 2) collect each.gdp_current color: #orange;
                data "Road Level 3" value: simulations where (each.initial_road_level = 3) collect each.gdp_current color: #yellow;
                data "Road Level 4" value: simulations where (each.initial_road_level = 4) collect each.gdp_current color: #green;
                data "Road Level 5" value: simulations where (each.initial_road_level = 5) collect each.gdp_current color: #blue;
            }
        }
    }
}