/**
* Name: UrbanPulse_Simplified
* Purpose: Explore how GDP emerges from micro-level interactions
* Extension: Analyze road upgrades' effects on productivity, happiness, credit stability, and GDP growth
* Author: anhnh
* Tags: economics, agent-based, GDP, infrastructure
*/

model UrbanPulse_Simplified

global {
	// =================================================================
	// SPATIAL DATA
	// =================================================================
	file shapefile_buildings <- file("../includes/buildings.shp");
	file shapefile_roads <- file("../includes/roads.shp");
	geometry shape <- envelope(shapefile_roads);
	graph road_network;
	
	// =================================================================
	// TIME CONTROL
	// =================================================================
	float step <- 5 #mn;
	date starting_date <- date("2026-01-01-00-00-00");
	int simulation_duration_months <- 3; // 3 months but can continue
	bool auto_pause <- false; // Don't auto-pause, let user decide
	
	// Time of day tracking
	int current_hour update: current_date.hour;
	bool is_work_hours <- true update: (current_hour >= 8 and current_hour < 18); // 8AM-6PM
	float work_population_factor <- 1.0 update: is_work_hours ? 1.0 : 0.2;
	
	// =================================================================
	// GLOBAL ASSUMPTIONS
	// =================================================================
	// Economy: closed, no inflation, no external investment, no imports/exports
	// Money supply: fixed at 37800 * N
	
	// =================================================================
	// POPULATION & AGENT COUNTS
	// =================================================================
	int nb_citizens <- 1000;
	int nb_factories <- 20;
	int nb_banks <- 3;
	int nb_markets <- 5;
	
	// =================================================================
	// MONEY SUPPLY & ALLOCATION
	// =================================================================
	float total_money_supply <- 37800.0 * nb_citizens;
	
	// =================================================================
	// GOVERNMENT STATE
	// =================================================================
	float government_reserves <- 0.0;
	float tax_rate <- 0.20; // adjustable: [0.1, 0.4]
	float government_infrastructure_spending <- 0.0; // monthly spending on roads
	float daily_income_tax_collected <- 0.0; // Track daily income tax
	float daily_corporate_tax_collected <- 0.0; // Track daily corporate tax
	float monthly_income_tax <- 0.0; // Cumulative monthly income tax
	float monthly_corporate_tax <- 0.0; // Cumulative monthly corporate tax
	
	// =================================================================
	// BANK STATE
	// =================================================================
	float bank_deposits <- 0.0;
	float bank_capital <- 0.0;
	float bank_total_loans <- 0.0;
	float annual_loan_interest_rate <- 0.08;
	float annual_savings_interest_rate <- 0.04;
	bool credit_freeze <- false; // triggered if bank capital ratio < 0.2
	float max_loan_to_capital_ratio <- 3.0; // Bank can't lend more than 3x its capital
	float max_individual_loan <- 1000000.0; // Maximum loan per factory
	
	// =================================================================
	// INFRASTRUCTURE STATE
	// =================================================================
	float road_capacity <- 1.0; // normalized capacity
	float road_durability <- 1.0; // degrades slowly over time
	float road_traffic <- 0.0; // computed from active travelers
	float road_congestion <- 0.0; // traffic / capacity
	float min_road_speed <- 2.0; // minimum 2 km/h even in traffic
	bool road_under_construction <- false;
	int road_construction_time_remaining <- 0; // in steps
	float road_construction_cost <- 0.0;
	road selected_road_for_upgrade <- nil; // Player selects which road to upgrade
	bool waiting_for_road_clear <- false; // Waiting for people to leave road
	
	// =================================================================
	// MARKET STATE
	// =================================================================
	float total_demand <- 0.0; // aggregate citizen spending
	float total_supply <- 0.0; // aggregate factory output
	
	// Happiness Goods Economy
	float happiness_goods_price <- 100.0; // Fixed price per unit (no inflation)
	float factory_daily_production_capacity <- 50.0; // Base units per day per factory
	int market_delivery_delay <- 2; // Days for factory -> market delivery
	
	// =================================================================
	// GDP COMPONENTS (Expenditure Approach: GDP = C + I + G)
	// =================================================================
	float gdp_consumption <- 0.0; // C: total market consumption
	float gdp_investment <- 0.0; // I: factory investment via loans
	float gdp_government <- 0.0; // G: government road spending
	float gdp_total <- 0.0;
	list<float> gdp_history <- [];
	
	// =================================================================
	// AGGREGATE METRICS
	// =================================================================
	float average_happiness <- 0.0;
	float average_productivity <- 0.0;
	float unemployment_rate <- 0.0;
	float loan_default_rate <- 0.0;
	float bank_capital_ratio <- 0.0;
	int simulation_month <- 0; // Track which month we're in
	
	// =================================================================
	// INITIALIZATION
	// =================================================================
	init {
		// Load spatial data
		if (shapefile_buildings != nil) {
			create building from: shapefile_buildings with: [height::int(read("HEIGHT"))];
		}
		if (shapefile_roads != nil) {
			create road from: shapefile_roads;
		}
		if (length(road) > 0) {
			road_network <- as_edge_graph(road);
		} else {
			write "WARNING: No roads loaded from shapefile!";
		}
		
		// Create banks and markets at specific buildings
		create bank number: nb_banks {
			location <- any_location_in(one_of(building));
		}
		create market number: nb_markets {
			location <- any_location_in(one_of(building));
		}
		
		// Initialize money supply distribution
		// Allocate initial reserves: uniform [0.05, 0.15] * estimated GDP
		float estimated_initial_gdp <- total_money_supply * 0.5;
		government_reserves <- estimated_initial_gdp * (0.05 + rnd(0.10));
		
		// Bank initial capital: 12% of expected deposits
		float estimated_deposits <- total_money_supply * 0.8;
		bank_capital <- estimated_deposits * 0.12;
		bank_deposits <- 0.0; // will accumulate from citizen savings
		
		// Remaining money for citizens and factories
		float remaining_money <- total_money_supply - government_reserves - bank_capital;
		
		// Create citizens
		float total_wealth_allocation <- remaining_money * 0.7; // 70% to citizens
		float total_salary_budget <- remaining_money * 0.1; // for initial salary setup
		
		create citizen number: nb_citizens {
			location <- any_location_in(one_of(building));
			
			// Generate lognormal wealth (median 25000, target Gini 0.35)
			wealth <- min(lognormal_rnd(25000.0, 15000.0), total_wealth_allocation);
			
			// Generate lognormal salary (median 3000) with correlation to wealth
			float base_salary <- lognormal_rnd(3000.0, 1500.0);
			salary <- base_salary + (wealth / 25000.0) * 500.0; // add wealth correlation
			
			// Generate normal happiness (mean 70, std 10)
			happiness <- min(max(gauss(70.0, 10.0), 0.0), 100.0);
			
			// Employment status (5% unemployed)
			employed <- flip(0.95);
			if (!employed) {
				salary <- 0.0;
			} else {
				// 20% of employed citizens work night shift
				is_night_shift <- flip(0.2);
			
			// Set individual work schedule with variation (Vietnam hours)
			if (is_night_shift) {
				// Night shift: 6PM-2AM with ±1 hour variation
				work_start_hour <- 18 + int(gauss(0.0, 1.0)); // 17-19
				work_end_hour <- 2 + int(gauss(0.0, 1.0)); // 1-3
			} else {
				// Day shift: 8AM-5:30PM with ±30 min variation
				work_start_hour <- 8 + int(gauss(0.0, 0.5)); // 7:30-8:30
				work_end_hour <- 18; // 5:30PM rounded to 6PM
			}}
			
			// Productivity based on happiness
			productivity <- 1.0 * (happiness / 100.0);
			
			// Spending behavior: wealthier people save more
			// Poor people (wealth < median): save 10-30%
			// Rich people (wealth > median): save 30-60%
			if (wealth < 25000.0) {
				savings_rate <- 0.1 + rnd(0.2); // 10-30%
				spending_fraction <- 1.0 - savings_rate;
			} else {
				savings_rate <- 0.3 + rnd(0.3); // 30-60%
				spending_fraction <- 1.0 - savings_rate;
			}
			home <- one_of(building);
			// Workplace will be assigned to factory location when hired
			
			// Individual consumption preferences
			consumption_desire <- 0.5 + rnd(1.0); // Range: 0.5-1.5 (low to high desire)
			price_sensitivity <- 0.5 + rnd(1.0); // Range: 0.5-1.5 (bargain hunter to luxury seeker)
			
			// Routing intelligence (different people make different choices)
			route_flexibility <- rnd(1.0); // 0 = stubborn (never changes route), 1 = adaptive
			speed_tolerance <- 5.0 + rnd(15.0); // km/h - will reroute if road slower than this
			reroute_check_frequency <- int(50 + rnd(200)); // steps between route checks
			prefer_fast_routes <- flip(0.7); // 70% prefer fast routes, 30% prefer short routes
		}
		
		// Normalize citizen wealth to match allocation
		float actual_total_wealth <- sum(citizen collect each.wealth);
		if (actual_total_wealth > 0) {
			ask citizen {
				wealth <- wealth * (total_wealth_allocation / actual_total_wealth);
			}
		}
		
		// Create factories
		float total_capital_allocation <- remaining_money * 0.3; // 30% to factories
		
		create factory number: nb_factories {
			location <- any_location_in(one_of(building));
			
			// Generate lognormal capital (median 500000)
			capital <- lognormal_rnd(500000.0, 250000.0);
			
			// Generate normal number of workers (mean 50, min 5)
			nb_workers <- max(5, int(gauss(50.0, 15.0)));
			
			// 40% of factories start with loans
			if (flip(0.4)) {
				loan_amount <- capital * rnd(0.3, 0.6);
				bank_total_loans <- bank_total_loans + loan_amount;
			}
			
			// Initialize profit history with small positive values (grace period)
			profit_history <- [1000.0, 500.0];
		}
		
		// Normalize factory capital to match allocation
		float actual_total_capital <- sum(factory collect each.capital);
		if (actual_total_capital > 0) {
			float capital_scale_factor <- total_capital_allocation / actual_total_capital;
			ask factory {
				capital <- capital * capital_scale_factor;
				// Also scale down loan_amount proportionally!
				loan_amount <- loan_amount * capital_scale_factor;
				// Scale down workers to match capital capacity
				// Ensure factory can afford at least 3 months of salaries
				float affordable_workers <- capital / (3000.0 * 3.0); // avg salary 3000, 3 months buffer
				nb_workers <- max(5, min(nb_workers, int(affordable_workers)));
			}
		}
		
		// Assign ALL employed citizens to factories (distribute evenly)
		list<citizen> employed_citizens <- citizen where each.employed;
		int total_employed <- length(employed_citizens);
		int workers_per_factory <- int(total_employed / nb_factories);
		
		list<citizen> unassigned <- employed_citizens;
		ask factory {
			if (length(unassigned) > 0) {
				// Assign workers_per_factory to each factory
				int to_assign <- min(workers_per_factory + 5, length(unassigned)); // +5 for remainder
				list<citizen> my_workers <- to_assign among unassigned;
				ask my_workers {
					workplace <- myself.location as building; // Set to factory's building
					
					// Set commute buffer based on distance (farther = leave earlier)
					float distance_km <- (location distance_to workplace) / 1000.0;
					// Assume 20 km/h average speed, add 0.5-1 hour buffer
					commute_buffer <- (distance_km / 20.0) + 0.5 + rnd(0.5);
					commute_buffer <- min(2.0, commute_buffer); // Cap at 2 hours early
				}
				unassigned <- unassigned - my_workers;
				// Update factory worker count to match reality
				nb_workers <- length(my_workers);
			}
		}
		
		// If any still unassigned, distribute to random factories
		if (length(unassigned) > 0) {
			ask unassigned {
				workplace <- (one_of(factory)).location as building;
				
				// Set commute buffer based on distance
				float distance_km <- (location distance_to workplace) / 1000.0;
				commute_buffer <- (distance_km / 20.0) + 0.5 + rnd(0.5);
				commute_buffer <- min(2.0, commute_buffer);
			}
		}
		
		write "=== UrbanPulse_Simplified Initialized ===";
		write "Citizens: " + nb_citizens;
		write "Factories: " + nb_factories;
		write "Total Money Supply: " + total_money_supply;
		write "Government Reserves: " + government_reserves;
		write "Bank Capital: " + bank_capital;
		write "Simulation Duration: " + simulation_duration_months + " months";
		write "";
		write "=== PLAYER CONTROLS ===";
		write "Click on any road to select it for upgrade (costs 50,000)";
		write "Blue = Selected | Purple = Waiting for road to clear | Orange = Under construction";
	}
	
	// =================================================================
	// PLAYER ACTIONS
	// =================================================================
	
	action select_road_for_upgrade (road selected) {
		if (selected != nil) {
			if (!selected.under_construction and !selected.waiting_to_upgrade) {
				selected_road_for_upgrade <- selected;
				float cost <- selected.upgrade_cost;
				int days <- selected.upgrade_duration;
				
				write "";
				write "=== ROAD SELECTED FOR UPGRADE ===";
				write "Road: " + selected;
				write "Length: " + int(selected.road_length) + " meters";
				write "Upgrade cost: $" + int(cost);
				write "Construction time: " + days + " days";
				write "Travelers on road: " + selected.nb_travelers;
				write "Government reserves: $" + int(government_reserves);
				write "";
				
				if (government_reserves >= cost) {
					write "✓ Upgrade approved! Road will slow down to clear traffic.";
					write "✓ Construction companies will receive contracts.";
				} else {
					write "✗ Not enough government funds! Need $" + int(cost - government_reserves) + " more.";
				}
			} else if (selected.waiting_to_upgrade) {
				write "This road is already waiting to be upgraded. " + selected.nb_travelers + " people still on it.";
			} else {
				write "This road is already under construction!";
			}
		}
	}
	
	// =================================================================
	// MONTHLY CYCLE
	// =================================================================
	
	// Step 1: Infrastructure and traffic calculation
	reflex update_infrastructure {
		// Update all roads
		ask road {
			do update_road_state;
		}
		
		// Calculate aggregate traffic from active workers
		int active_citizens <- length(citizen where each.is_working);
		float population_traffic <- active_citizens * work_population_factor;
		float factory_traffic <- sum(factory collect each.output) * 0.001;
		road_traffic <- population_traffic + factory_traffic;
		
		// Calculate congestion
		float total_road_capacity <- sum(road collect each.capacity);
		road_congestion <- road_traffic / (total_road_capacity + 0.01);
	}
	
	// Step 2: Citizens commute, update happiness, productivity, and spending
	reflex citizen_activities {
		ask citizen {
			do commute;
			do update_happiness;
			do update_productivity;
			do spend_and_save;
		}
		
		// Aggregate metrics
		average_happiness <- mean(citizen collect each.happiness);
		average_productivity <- mean(citizen collect (each.employed ? each.productivity : 0.0));
		unemployment_rate <- length(citizen where (!each.employed)) / nb_citizens;
	}
	
	// Step 3: Market clears (match demand and supply)
	reflex market_clearing when: every(24 #hour) {
		total_demand <- sum(citizen collect each.monthly_spending);
		total_supply <- sum(factory collect each.output);
		
		// Market consumption is the minimum of demand and supply
		gdp_consumption <- min(total_demand, total_supply);
		
		// Calculate average item cost (varies daily)
		float supply_demand_ratio <- total_supply / (total_demand + 0.01);
		float base_item_cost <- 100.0; // base cost per unit
		float actual_item_cost <- base_item_cost * (1.0 + rnd(-0.3, 0.3)); // ±30% variation
		
		// If demand > supply, prices go up (scarcity)
		if (supply_demand_ratio < 1.0) {
			actual_item_cost <- actual_item_cost * (1.0 + (1.0 - supply_demand_ratio));
		}
		
		// Distribute consumption happiness to citizens with individual variations
		float per_capita_consumption <- gdp_consumption / (nb_citizens + 0.01);
		ask citizen {
			// Base satisfaction from consumption
			float consumption_amount <- per_capita_consumption * (monthly_spending / (total_demand + 0.01));
			
			// Happiness depends on:
			// 1. How much they consumed (logarithmic returns)
			// 2. Their individual desire level
			// 3. Whether prices matched their expectations
			float base_satisfaction <- ln(consumption_amount + 1.0) * consumption_desire;
			
			// Price effect: luxury seekers like expensive items, bargain hunters don't
			float price_effect <- (actual_item_cost / base_item_cost - 1.0) * (price_sensitivity - 1.0);
			
			// Final consumption happiness (individual variation)
			consumption_happiness <- (base_satisfaction + price_effect) * 3.0;
			happiness <- happiness + consumption_happiness * 0.1; // small daily boost
			happiness <- min(100.0, max(0.0, happiness));
		}
	}
	
	// Step 4: Factories produce daily (visible), but financial operations monthly
	reflex factory_daily_operations {
		ask factory {
			do produce; // Produce every step for visualization
		}
	}
	
	// Factory financial operations happen monthly (skip first month for startup grace period)
	reflex factory_monthly_operations when: (current_date.day = 1 and current_date.hour = 0 and simulation_month > 0) {
		ask factory {
			do pay_salaries;
			do handle_loan_payments;
			do evaluate_investment;
			do check_profitability;
			do consider_hiring; // NEW: Try to hire if profitable
		}
		
		// Calculate loan default rate
		float total_defaults <- sum(factory collect each.defaulted_amount);
		loan_default_rate <- total_defaults / (bank_total_loans + 0.01);
	}
	
	// Step 5: Bank operations (interest on deposits, check stability)
	reflex bank_operations {
		// Pay interest on deposits (monthly rate)
		float monthly_savings_rate <- annual_savings_interest_rate / 12.0;
		float interest_paid <- bank_deposits * monthly_savings_rate;
		bank_capital <- bank_capital - interest_paid;
		
		// Distribute interest to citizens
		ask citizen {
			float my_interest <- savings * monthly_savings_rate;
			wealth <- wealth + my_interest;
			savings <- savings + my_interest;
		}
		
		// Update bank deposits
		bank_deposits <- sum(citizen collect each.savings);
		
		// Check bank stability
		bank_capital_ratio <- bank_capital / (bank_deposits + 0.01);
		
		if (bank_capital_ratio < 0.2 and !credit_freeze) {
			credit_freeze <- true;
			write "!!! BANK RUN TRIGGERED !!! Credit freeze activated.";
		}
	}
	
	// Step 6: Government collects taxes and manages infrastructure
	reflex government_operations when: every(24 #hour) {
		// Collect income taxes from citizens (daily basis)
		daily_income_tax_collected <- 0.0;
		ask citizen where (each.employed and each.is_working) {
			float daily_salary <- salary / 30.0; // monthly salary to daily
			float tax_amount <- daily_salary * tax_rate;
			wealth <- wealth - tax_amount;
			daily_income_tax_collected <- daily_income_tax_collected + tax_amount;
		}
		
		// Collect corporate taxes from factories (daily)
		daily_corporate_tax_collected <- 0.0;
		ask factory where (each.monthly_profit > 0) {
			float daily_profit <- monthly_profit / 30.0;
			float tax_amount <- daily_profit * tax_rate;
			capital <- capital - tax_amount;
			daily_corporate_tax_collected <- daily_corporate_tax_collected + tax_amount;
		}
		
		// Update reserves and monthly totals
		government_reserves <- government_reserves + daily_income_tax_collected + daily_corporate_tax_collected;
		monthly_income_tax <- monthly_income_tax + daily_income_tax_collected;
		monthly_corporate_tax <- monthly_corporate_tax + daily_corporate_tax_collected;
		
		// Show tax collection every day at noon
		if (current_date.hour = 12) {
			write "Daily Tax Collection | Income Tax: $" + int(daily_income_tax_collected) + 
			      " | Corporate Tax: $" + int(daily_corporate_tax_collected) + 
			      " | Total Today: $" + int(daily_income_tax_collected + daily_corporate_tax_collected) +
			      " | Gov Reserves: $" + int(government_reserves);
		}
		
		// Player can click on roads to select them for upgrade
		// When player triggers upgrade (via UI):
		if (selected_road_for_upgrade != nil and !selected_road_for_upgrade.waiting_to_upgrade and !selected_road_for_upgrade.under_construction) {
			// Check if government can afford (cost based on road size)
			float upgrade_cost <- selected_road_for_upgrade.upgrade_cost;
			
			if (government_reserves >= upgrade_cost) {
				// Deduct from government reserves
				government_reserves <- government_reserves - upgrade_cost;
				
				// === MONEY FLOW TO CONSTRUCTION COMPANIES ===
				// Select 2-3 factories to act as construction companies
				int num_contractors <- int(2 + rnd(2)); // 2-4 contractors
				list<factory> construction_companies <- num_contractors among factory;
				
				// Distribute contract money to these factories
				// This money will:
				// 1. Increase their capital
				// 2. Help them invest/expand
				// 3. Pay more salaries (hire more workers)
				// 4. Generate more taxes back to government
				// 5. Increase overall GDP (government spending)
				ask construction_companies {
					float contract_share <- upgrade_cost / num_contractors;
					capital <- capital + contract_share;
					
					write "Factory " + name + " received construction contract: $" + int(contract_share);
					write "   → New capital: $" + int(capital) + " (can invest/hire more workers)";
				}
				
				// Mark road as waiting for people to leave
				selected_road_for_upgrade.waiting_to_upgrade <- true;
				
				write "";
				write "✓ Road upgrade contract awarded!";
				write "✓ $" + int(upgrade_cost) + " distributed to " + num_contractors + " construction companies";
				write "✓ Waiting for " + selected_road_for_upgrade.nb_travelers + " people to leave the road...";
				write "";
				
				selected_road_for_upgrade <- nil; // Clear selection
				government_infrastructure_spending <- upgrade_cost;
			} else {
				write "✗ Not enough government reserves for road upgrade.";
				write "   Need: $" + int(upgrade_cost) + ", Have: $" + int(government_reserves);
			}
		}
		
		gdp_government <- government_infrastructure_spending;
		government_infrastructure_spending <- 0.0; // Reset for next period
	}
	
	// Step 7: Calculate GDP (monthly) - at END of month
	reflex calculate_gdp when: (current_date.day = 28 and current_date.hour = 23) {
		simulation_month <- simulation_month + 1;
		gdp_investment <- sum(factory collect each.monthly_investment);
		gdp_total <- gdp_consumption + gdp_investment + gdp_government;
		gdp_history <- gdp_history + gdp_total;
		
		int month_num <- simulation_month;
		write "Month " + month_num + " | GDP: " + int(gdp_total) + 
			  " | C: " + int(gdp_consumption) + 
			  " | I: " + int(gdp_investment) + 
			  " | G: " + int(gdp_government) +
			  " | Happiness: " + round(average_happiness * 10) / 10 +
			  " | Unemployment: " + round(unemployment_rate * 1000) / 10 + "%" +
			  " | Time: " + current_date;
		
		// Monthly tax summary
		write "Monthly Tax Summary | Income Tax: $" + int(monthly_income_tax) +
		      " | Corporate Tax: $" + int(monthly_corporate_tax) +
		      " | Total Tax: $" + int(monthly_income_tax + monthly_corporate_tax);
		
		// Reset monthly counters
		monthly_income_tax <- 0.0;
		monthly_corporate_tax <- 0.0;
		
		// Show summary but don't pause - user can continue or reset
		if (month_num = simulation_duration_months) {
			write "=== " + simulation_duration_months + " MONTHS COMPLETE ===";
			write "You can continue the simulation or reset for a new experiment.";
			write "GDP: " + int(gdp_total) + " | Avg Happiness: " + round(average_happiness);
		}
	}
}

// =================================================================
// SPECIES DEFINITIONS
// =================================================================

species building {
	float height;
	
	aspect default {
		draw shape color: #gray border: #black; // Flat for visibility
	}
}

species bank {
	aspect default {
		draw circle(15) color: #gold border: #black depth: 20;
		draw sphere(8) at: location color: #yellow; // Gold sphere marker
	}
}

species market {
	int nb_visitors <- 0 update: length(citizen at_distance 20);
	float happiness_goods_stock <- 500.0; // Starting inventory
	list<float> pending_delivery_amounts <- []; // Parallel lists for deliveries
	list<date> pending_delivery_dates <- [];
	float total_sales_today <- 0.0;
	
	// Receive deliveries that have arrived
	reflex receive_deliveries {
		if (length(pending_delivery_dates) > 0) {
			list<int> indices_to_remove <- [];
			loop i from: 0 to: length(pending_delivery_dates) - 1 {
				if (current_date >= pending_delivery_dates[i]) {
					happiness_goods_stock <- happiness_goods_stock + pending_delivery_amounts[i];
					indices_to_remove <- indices_to_remove + i;
				}
			}
			// Remove arrived deliveries (in reverse order to maintain indices)
			if (length(indices_to_remove) > 0) {
				loop i from: length(indices_to_remove) - 1 to: 0 step: -1 {
					int idx <- indices_to_remove[i];
					pending_delivery_amounts <- pending_delivery_amounts - pending_delivery_amounts[idx];
					pending_delivery_dates <- pending_delivery_dates - pending_delivery_dates[idx];
				}
			}
		}
	}
	
	// Order from factories when stock is low
	reflex restock_from_factories when: (happiness_goods_stock < 200.0 and every(12 #hour)) {
		// Find factories with production capacity
		list<factory> available_factories <- factory where (each.happiness_goods_inventory > 10.0);
		if (length(available_factories) > 0) {
			factory supplier <- one_of(available_factories);
			float order_amount <- min(100.0, supplier.happiness_goods_inventory);
			
			// Factory ships goods (removed from their inventory immediately)
			ask supplier {
				happiness_goods_inventory <- happiness_goods_inventory - order_amount;
			}
			
			// Add to pending deliveries (arrives after delay)
			date arrival <- current_date add_days market_delivery_delay;
		pending_delivery_amounts <- pending_delivery_amounts + order_amount;
		pending_delivery_dates <- pending_delivery_dates + arrival;
	}
}
	
	aspect default {
		// Color based on stock level: green (high), yellow (medium), red (low)
		rgb stock_color <- happiness_goods_stock > 300 ? #green : (happiness_goods_stock > 100 ? #yellow : #red);
		draw square(18) color: stock_color border: #darkgreen depth: 15;
		draw cone3D(12, 8) at: location color: stock_color; // Market canopy
	}
}

species road {
	float capacity <- 1.0 + shape.perimeter / 30.0;
	int nb_travelers <- 0;
	float current_speed <- 30.0; // km/h
	bool under_construction <- false;
	bool waiting_to_upgrade <- false; // Marked for upgrade, waiting for empty
	int construction_time <- 0;
	int upgrade_timer <- 0; // How long waiting for people to leave
	
	// Count travelers actively using this road
	reflex count_travelers {
		nb_travelers <- length(citizen where (each.my_path != nil and each.my_path.edges contains self));
		
		// Update speed based on traffic (every step for responsive visuals)
		if (!under_construction and !waiting_to_upgrade) {
			float congestion_factor <- nb_travelers / (capacity + 0.1);
			current_speed <- max(min_road_speed, 30.0 * exp(-congestion_factor * 0.5));
		} else if (waiting_to_upgrade) {
			// Slow down to encourage people to leave
			current_speed <- min_road_speed * 0.5;
		} else {
			// Under construction - very slow
			current_speed <- min_road_speed * 0.1;
		}
	}
	
	// Road size determines cost and construction time
	float road_length <- shape.perimeter;
	float upgrade_cost <- 0.0 update: calculate_upgrade_cost();
	int upgrade_duration <- 0 update: calculate_upgrade_duration(); // in days
	
	float calculate_upgrade_cost {
		// Cost based on road size: $200 per meter
		// Small roads (100m): ~20,000
		// Medium roads (250m): ~50,000
		// Large roads (500m): ~100,000
		return road_length * 200.0;
	}
	
	int calculate_upgrade_duration {
		// Duration: 1 day per 10 meters
		// Small roads: ~10 days
		// Medium roads: ~25 days
		// Large roads: ~50 days
		return max(7, int(road_length / 10.0)); // minimum 7 days
	}
	
	action update_road_state {
		// If waiting for people to leave before starting upgrade
		if (waiting_to_upgrade and !under_construction) {
			if (nb_travelers = 0) {
				// Road is empty! Start construction
				under_construction <- true;
				waiting_to_upgrade <- false;
				construction_time <- int(upgrade_duration #day / step); // Use calculated duration
				upgrade_timer <- 0;
				write "Road construction started on " + self + " (" + road_length + "m, will take " + upgrade_duration + " days)";
			} else {
				// Still waiting, display warning
				upgrade_timer <- upgrade_timer + 1;
				if (upgrade_timer mod int(1 #hour / step) = 0) {
					write "Waiting for " + nb_travelers + " people to leave road before upgrade...";
				}
			}
		}
		
		// Handle construction progress
		if (under_construction) {
			construction_time <- construction_time - 1;
			if (construction_time <= 0) {
				under_construction <- false;
				capacity <- capacity * 1.5; // Upgrade complete!
				write "Road upgrade completed at " + current_date + " on " + self + ": capacity increased 50%!";
			}
		}
	}
	
	aspect default {
		// Color based purely on speed: Red (slow) -> Yellow (medium) -> Green (fast)
		float speed_ratio <- (current_speed - min_road_speed) / (30.0 - min_road_speed);
		rgb road_color;
		
		if (under_construction) {
			road_color <- #orange; // Orange = construction in progress
		} else if (waiting_to_upgrade) {
			road_color <- #purple; // Purple = waiting for road to clear
		} else if (self = selected_road_for_upgrade) {
			road_color <- #blue; // Blue = selected by player
		} else {
			// Speed-based gradient: Red (2 km/h) -> Yellow (16 km/h) -> Green (30 km/h)
			road_color <- rgb(int(255 * (1 - speed_ratio)), int(255 * speed_ratio), 0);
		}
		
		float width <- under_construction ? 5.0 : (2.0 + 3.0 * (1 - speed_ratio));
		draw shape color: road_color width: width;
	}
}

species citizen skills: [moving] {
	// State variables
	float wealth;
	float salary;
	float happiness;
	bool employed;
	float productivity;
	float spending_fraction;
	float savings <- 0.0;
	float savings_rate <- 0.0; // How much of income to save (wealth-dependent)
	bool is_working <- false;
	bool is_night_shift <- false; // 20% work night shift (10PM-6AM)
	
	// Shopping behavior
	int days_since_shopping <- int(rnd(7)); // Stagger initial shopping days
	float happiness_goods_owned <- rnd(50.0); // Current happiness goods
	
	// Individual work schedule (varies by person and commute)
	int work_start_hour <- 6; // When they start work (day shift 6-10, night shift varies)
	int work_end_hour <- 22; // When they end work
	float commute_buffer <- 0.0; // Extra time to leave early for commute (in hours)
	
	// Spatial
	building home;
	building workplace;
	point target <- nil;
	float commute_time <- 0.0;
	string activity_state <- "home"; // home, commuting, at_work, shopping, returning
	
	// Routing intelligence
	float route_flexibility <- 0.0; // How likely to change route (0-1)
	float speed_tolerance <- 0.0; // Min acceptable speed before rerouting
	int reroute_check_frequency <- 0; // How often to check for better routes
	int steps_since_reroute_check <- 0;
	path my_path <- nil; // Renamed from current_path to avoid conflict with moving skill
	bool prefer_fast_routes <- true;
	
	// Monthly flows
	float monthly_spending <- 0.0;
	float consumption_happiness <- 0.0;
	float consumption_desire <- 1.0; // Individual desire for consumption (varies)
	float price_sensitivity <- 1.0; // How sensitive to item costs (varies)
	
	// Actions
	action commute {
		// Calculate individual work hours based on schedule and commute
		float effective_start <- work_start_hour - commute_buffer;
		float effective_end <- work_end_hour;
		
		// Check if currently in work time window
		bool in_work_window <- (current_hour >= int(effective_start) and current_hour < effective_end);
		
		// Only commute during work hours and if employed
		if (employed and in_work_window and workplace != nil) {
			is_working <- true;
			
			// Intelligent route planning
			point workplace_location <- any_location_in(workplace);
			
			// Decide whether to calculate new route
			bool need_new_route <- (my_path = nil);
			
			// Periodically check if should reroute (based on personality)
			steps_since_reroute_check <- steps_since_reroute_check + 1;
			if (steps_since_reroute_check >= reroute_check_frequency) {
				steps_since_reroute_check <- 0;
				// Flexible people more likely to reroute
				if (flip(route_flexibility)) {
					need_new_route <- true;
				}
			}
			
			// Check if current path has slow roads ahead
			if (my_path != nil and !need_new_route) {
				list<road> path_roads <- my_path.edges collect road(each);
				if (length(path_roads) > 0) {
					// Check if any road on path is too slow
					list<road> slow_roads <- path_roads where (each.current_speed < speed_tolerance);
					if (length(slow_roads) > 0) {
						// Road ahead is slow! Consider rerouting
						// More flexible people more likely to reroute
						if (flip(route_flexibility * 0.8)) {
							need_new_route <- true;
						}
					}
				}
			}
			
			// Calculate route (avoiding construction, considering speed)
			if (need_new_route) {
				// Find roads not under construction
				list<road> available_roads <- road where (!each.under_construction);
				
				if (length(available_roads) > 0) {
					// Create weighted graph based on preference
					map<road, float> road_weights <- available_roads as_map (
						each::(
							prefer_fast_routes ? 
								// Weight by speed (slower roads = higher cost)
								(each.shape.perimeter / (each.current_speed + 0.1)) :
								// Weight by distance only
								each.shape.perimeter
						)
					);
					
					graph weighted_network <- as_edge_graph(available_roads) with_weights road_weights;
					my_path <- weighted_network path_between (location, workplace_location);
					
					if (my_path != nil) {
						list<road> path_roads <- my_path.edges collect road(each);
						if (length(path_roads) > 0) {
							float avg_speed <- mean(path_roads collect max(min_road_speed, each.current_speed));
							float distance <- location distance_to workplace_location;
							commute_time <- (distance / 1000.0) / (avg_speed + 0.01) * 60.0; // in minutes
						} else {
							commute_time <- 30.0;
						}
					} else {
						commute_time <- 45.0; // no path found
						my_path <- nil;
					}
				} else {
					// All roads under construction
					commute_time <- 60.0;
					my_path <- nil;
				}
			}
			
			// Actually move to workplace for visualization
			if (target = nil or (target distance_to location) < 10.0) {
				// At work, stay near workplace
				if (workplace != nil) {
					target <- any_location_in(workplace);
					activity_state <- "at_work";
				}
			}
		} else {
			is_working <- false;
			commute_time <- 0.0;
			my_path <- nil; // Reset path when not working
			
			// Off-duty behavior depends on shift type
			if (is_night_shift) {
				// Night shift workers: sleep during day, shop in evening
				if (current_hour >= 8 and current_hour < 18) {
					// Daytime: sleep at home
					if (home != nil and (target = nil or activity_state != "home")) {
						target <- any_location_in(home);
						activity_state <- "home";
					}
				} else if (current_hour >= 18 and current_hour < 22) {
					// Evening: shop before night shift (40% market, 10% bank)
					if (target = nil or (target distance_to location) < 10.0) {
						if (flip(0.40)) {
							// 40% chance: visit market
							market closest_market <- market closest_to location;
							if (closest_market != nil) {
								target <- closest_market.location;
								activity_state <- "shopping";
							}
						} else if (flip(0.10)) {
							// 10% chance: visit bank
							bank closest_bank <- bank closest_to location;
							if (closest_bank != nil) {
								target <- closest_bank.location;
								activity_state <- "banking";
							}
						}
					}
				}
			} else {
				// Day shift workers: normal evening/night behavior  
				if (current_hour >= 8 and current_hour < 18) {
					// Work hours but not working: small chance to visit market (5%) or bank (3%)
					if (target = nil or (target distance_to location) < 10.0) {
						if (flip(0.05)) {
							// 5% chance: quick market trip during day
							market closest_market <- market closest_to location;
							if (closest_market != nil) {
								target <- closest_market.location;
								activity_state <- "shopping";
							}
						} else if (flip(0.03)) {
							// 3% chance: bank visit during day
							bank closest_bank <- bank closest_to location;
							if (closest_bank != nil) {
								target <- closest_bank.location;
								activity_state <- "banking";
							}
						}
					}
				} else if (current_hour >= 18 and current_hour < 22) {
					// Evening: visit market if need goods, otherwise bank
					if (target = nil or (target distance_to location) < 10.0) {
						// Higher chance to shop if running low on happiness goods
						bool need_shopping <- (days_since_shopping >= 3 and happiness_goods_owned < 10.0);
						float shopping_chance <- need_shopping ? 0.60 : 0.20;
						
						if (flip(shopping_chance)) {
							// Evening shopping
							market closest_market <- market closest_to location;
							if (closest_market != nil) {
								target <- closest_market.location;
								activity_state <- "shopping";
								// Buy goods when arrive at market
								if (location distance_to target < 15.0) {
									do buy_happiness_goods;
								}
							}
						} else if (flip(0.15)) {
							// 15% chance: evening banking
							bank closest_bank <- bank closest_to location;
							if (closest_bank != nil) {
								target <- closest_bank.location;
								activity_state <- "banking";
							}
						}
					}
				} else if (current_hour >= 22 or current_hour < 6) {
					// Night: only day shift workers go home (night shift is working!)
					if (!is_night_shift) {
						if (home != nil and (target = nil or activity_state != "home")) {
							target <- any_location_in(home);
							activity_state <- "home";
						}
					}
				}
				
				// Unemployed during day: higher chance to wander/visit places
				if (!employed and current_hour >= 8 and current_hour < 18) {
					if (flip(0.10)) {
						// 10% chance: unemployed visit market or bank
						if (flip(0.5)) {
							market closest_market <- market closest_to location;
							if (closest_market != nil) {
								target <- closest_market.location;
								activity_state <- "shopping";
							}
						} else {
							bank closest_bank <- bank closest_to location;
							if (closest_bank != nil) {
								target <- closest_bank.location;
								activity_state <- "banking";
							}
						}
					}
				}
			}
		}
	}
	
	action update_happiness {
		// Consume happiness goods daily (1 unit per day)
		if (happiness_goods_owned >= 1.0) {
			happiness_goods_owned <- happiness_goods_owned - 1.0;
			happiness <- min(100.0, happiness + 5.0); // Boost happiness
		} else {
			// No goods = happiness decays faster
			happiness <- happiness - 3.0;
		}
		
		// Happiness decreases with commute time
		float commute_penalty <- commute_time * 0.5;
		happiness <- happiness - commute_penalty;
		
		// Employment status affects happiness
		if (!employed) {
			happiness <- happiness - 2.0;
		}
		
		// Natural happiness drift toward mean (70)
		happiness <- happiness + (70.0 - happiness) * 0.05;
		
		// Bounds
		happiness <- max(0.0, min(100.0, happiness));
		
		// Decide if need to go shopping (every 3-7 days)
		days_since_shopping <- days_since_shopping + 1;
		if (days_since_shopping >= (3 + rnd(5)) and happiness_goods_owned < 10.0) {
			// Need to shop soon!
			// Will trigger in commute action based on time of day
		}
	}
	
	action update_productivity {
		// Base productivity modified by happiness
		productivity <- 1.0 * (happiness / 100.0);
		
		// Quiet quitting: if happiness < 40, productivity drops to 50%
		if (happiness < 40.0) {
			productivity <- productivity * 0.5;
		}
	}
	
	action spend_and_save {
		if (employed) {
			// Spend a fraction of salary
			monthly_spending <- salary * spending_fraction;
			
			// Save the rest in bank
			float monthly_savings <- salary * savings_rate;
			savings <- savings + monthly_savings;
			
			// Update wealth
			wealth <- wealth + monthly_savings;
		} else {
			monthly_spending <- 0.0;
		}
	}
	
	action buy_happiness_goods {
		// Find closest market
		market closest_market <- market closest_to location;
		if (closest_market != nil and closest_market.happiness_goods_stock > 0) {
			// Buying power based on wealth (richer people buy more)
			// Poor (<15k): 1-3 units, Middle (15-35k): 3-7 units, Rich (>35k): 7-15 units
			float desired_units <- 0.0;
			if (wealth < 15000.0) {
				desired_units <- 1.0 + rnd(2.0);
			} else if (wealth < 35000.0) {
				desired_units <- 3.0 + rnd(4.0);
			} else {
				desired_units <- 7.0 + rnd(8.0);
			}
			
			float total_cost <- desired_units * happiness_goods_price;
			
			// Can only buy what market has and what we can afford
			float actual_units <- min(desired_units, closest_market.happiness_goods_stock);
			actual_units <- min(actual_units, wealth / happiness_goods_price);
			
			if (actual_units >= 1.0) {
				float actual_cost <- actual_units * happiness_goods_price;
				
				// Buy goods
				wealth <- wealth - actual_cost;
				happiness_goods_owned <- happiness_goods_owned + actual_units;
				
				// Market updates
				ask closest_market {
					happiness_goods_stock <- happiness_goods_stock - actual_units;
					total_sales_today <- total_sales_today + actual_cost;
				}
				
				days_since_shopping <- 0;
			}
		}
	}
	
	reflex move when: (target != nil) {
		// Use current road speed (affected by congestion)
		// Find the road we're currently on
		road current_road <- road closest_to location;
		float movement_speed <- 5.0 #km/#h; // default
		
		if (current_road != nil) {
			// Use the road's current speed (accounts for traffic/construction)
			movement_speed <- current_road.current_speed #km/#h;
		}
		
		do goto target: target on: road_network speed: movement_speed;
		if (location distance_to target < 10.0) {
			target <- nil;
		}
	}
	
	aspect default {
		// Cyan = day shift working, Blue = night shift working, Yellow = employed but off-duty, Red = unemployed
		rgb citizen_color;
		if (is_working) {
			citizen_color <- is_night_shift ? #blue : #cyan;
		} else if (employed) {
			citizen_color <- #yellow;
		} else {
			citizen_color <- #red;
		}
		draw circle(5) color: citizen_color;
	}
}

species factory {
	// State variables
	float capital;
	int nb_workers;
	float loan_amount <- 0.0;
	list<float> profit_history;
	
	// Happiness Goods Production
	float happiness_goods_inventory <- 100.0; // Current stock
	float production_capacity <- factory_daily_production_capacity; // Units per day
	float production_cost_per_unit <- 50.0; // Cost to produce one unit
	
	// Monthly flows
	float output <- 0.0;
	float monthly_profit <- 0.0;
	float monthly_investment <- 0.0;
	float defaulted_amount <- 0.0;
	
	// Actions
	action produce {
		// Get employed citizens assigned to this factory
		list<citizen> workers <- nb_workers among (citizen where (each.employed));
		
		// Calculate average productivity
		float avg_productivity <- mean(workers collect each.productivity);
		if (avg_productivity = 0.0) {
			avg_productivity <- 0.5;
		}
		
		// Production function: output depends on workers, productivity, and road efficiency
		float road_eff <- 1.0 / (1.0 + road_congestion * 0.5);
		output <- nb_workers * avg_productivity * road_eff * 100.0;
		
		// Diminishing returns
		output <- output * (1.0 - (nb_workers / 200.0));
		
		// Produce happiness goods (daily, if can afford)
		float daily_production <- production_capacity * avg_productivity * road_eff;
		float production_cost <- daily_production * production_cost_per_unit;
		
		if (capital >= production_cost) {
			capital <- capital - production_cost;
			happiness_goods_inventory <- happiness_goods_inventory + daily_production;
		} else {
			// Can only produce what we can afford
			float affordable_units <- capital / production_cost_per_unit;
			if (affordable_units > 1.0) {
				capital <- capital - (affordable_units * production_cost_per_unit);
				happiness_goods_inventory <- happiness_goods_inventory + affordable_units;
			}
		}
	}
	
	action pay_salaries {
		// Pay salaries to workers
		list<citizen> workers <- nb_workers among (citizen where (each.employed));
		ask workers {
			// Salary already defined in citizen initialization
		}
		
		// Deduct salary costs from capital
		float total_salary_cost <- sum(workers collect each.salary);
		capital <- capital - total_salary_cost;
	}
	
	action handle_loan_payments {
		if (loan_amount > 0) {
			// Monthly loan payment (principal + interest)
			float monthly_interest_rate <- annual_loan_interest_rate / 12.0;
			float monthly_payment <- loan_amount * monthly_interest_rate;
			
			if (capital >= monthly_payment) {
				capital <- capital - monthly_payment;
				bank_capital <- bank_capital + monthly_payment;
			} else {
				// Default on loan
				defaulted_amount <- monthly_payment;
				bank_capital <- bank_capital - defaulted_amount;
				write "Factory defaulted on loan: " + defaulted_amount;
			}
		}
	}
	
	action evaluate_investment {
		// Investment triggered if expected profit is positive
		monthly_investment <- 0.0;
		
		float avg_profit <- mean(profit_history);
		if (avg_profit > 0 and !credit_freeze) {
			// Calculate desired investment
			float desired_investment <- min(avg_profit * 0.5, max_individual_loan);
			
			// Check bank lending capacity
			float bank_lending_capacity <- (bank_capital * max_loan_to_capital_ratio) - bank_total_loans;
			
			// Only invest if bank can lend
			if (bank_lending_capacity > 1000.0 and desired_investment > 0) {
				float actual_investment <- min(desired_investment, bank_lending_capacity);
				monthly_investment <- actual_investment;
				loan_amount <- loan_amount + actual_investment;
				bank_total_loans <- bank_total_loans + actual_investment;
				capital <- capital + actual_investment;
				
				// Use 50% of investment to increase production capacity
				float capacity_investment <- actual_investment * 0.5;
				production_capacity <- production_capacity + (capacity_investment / 10000.0); // +0.1 capacity per 1000 invested
			}
		}
	}
	
	action check_profitability {
		// Calculate monthly profit
		monthly_profit <- output * 10.0 - sum((nb_workers among citizen) collect each.salary);
		
		// Update profit history
		profit_history <- profit_history + monthly_profit;
		if (length(profit_history) > 3) {
			profit_history <- profit_history[1::2]; // keep last 3
		}
		
		// Layoff decision: if profit negative for 3 consecutive months
		if (length(profit_history) >= 3) {
			list<float> last_3_profits <- profit_history[length(profit_history)-3::length(profit_history)-1];
			if (sum(last_3_profits) < 0) {
				// Lay off 20% of workers
				int layoff_count <- int(nb_workers * 0.2);
				if (layoff_count > 0) {
					list<citizen> workers <- nb_workers among (citizen where (each.employed and each.workplace = self));
					list<citizen> to_layoff <- min(layoff_count, length(workers)) among workers;
					
					ask to_layoff {
						employed <- false;
						salary <- 0.0;
						workplace <- nil;
					}
					
					nb_workers <- nb_workers - length(to_layoff);
					
					// Only report if workers were actually laid off
					if (length(to_layoff) > 0) {
						write "Factory laid off " + length(to_layoff) + " workers after 3 months of losses";
					}
				}
			}
		}
		
		// Bankruptcy: if capital < 0
		if (capital < 0) {
			write "Factory bankrupt!";
			defaulted_amount <- loan_amount;
			bank_capital <- bank_capital - loan_amount;
			do die;
		}
	}
	
	action consider_hiring {
		// If profitable for 2+ consecutive months, consider hiring
		if (length(profit_history) >= 2) {
			list<float> last_2_profits <- profit_history[length(profit_history)-2::length(profit_history)-1];
			if (sum(last_2_profits) > 0 and capital > 50000) {
				// Try to hire unemployed citizens (up to 10% growth)
				int max_new_hires <- max(1, int(nb_workers * 0.1));
				list<citizen> unemployed <- citizen where (!each.employed);
				
				if (length(unemployed) > 0) {
					int actual_hires <- min(max_new_hires, length(unemployed));
					list<citizen> new_hires <- actual_hires among unemployed;
					
					ask new_hires {
						employed <- true;
						workplace <- myself.location as building;
						salary <- lognormal_rnd(3000.0, 1000.0);
						
						// Set work schedule and commute buffer (Vietnam hours)
						is_night_shift <- flip(0.2);
						if (is_night_shift) {
							work_start_hour <- 18 + int(gauss(0.0, 1.0)); // 17-19
							work_end_hour <- 2 + int(gauss(0.0, 1.0)); // 1-3
						} else {
							work_start_hour <- 8 + int(gauss(0.0, 0.5)); // 7:30-8:30
							work_end_hour <- 18; // 6PM
						}
						
						float distance_km <- (location distance_to workplace) / 1000.0;
						commute_buffer <- (distance_km / 20.0) + 0.5 + rnd(0.5);
						commute_buffer <- min(2.0, commute_buffer);
					}
					
					nb_workers <- nb_workers + length(new_hires);
					write "Factory hired " + length(new_hires) + " workers (profitable growth)";
				}
			}
		}
	}
	
	aspect default {
		rgb factory_color <- monthly_profit > 0 ? #blue : #orange;
		draw square(20) color: factory_color border: #black;
	}
}

// =================================================================
// EXPERIMENT
// =================================================================

experiment UrbanPulse_Simulation type: gui {
	// Parameters
	parameter "Number of Citizens" var: nb_citizens min: 100 max: 5000 category: "Population";
	parameter "Number of Factories" var: nb_factories min: 5 max: 100 category: "Economy";
	parameter "Tax Rate" var: tax_rate min: 0.1 max: 0.4 step: 0.05 category: "Government";
	parameter "Loan Interest Rate (Annual)" var: annual_loan_interest_rate min: 0.01 max: 0.20 step: 0.01 category: "Banking";
	parameter "Savings Interest Rate (Annual)" var: annual_savings_interest_rate min: 0.0 max: 0.10 step: 0.01 category: "Banking";
	parameter "Simulation Duration (Months)" var: simulation_duration_months min: 6 max: 24 category: "Time";
	
	output {
		// Main Map Display
		display "Urban Map" type: 3d axes: false background: (current_hour >= 6 and current_hour < 20) ? #white : #black {
			species building aspect: default refresh: false;
			species road aspect: default;
			species bank aspect: default;
			species market aspect: default;
			species citizen aspect: default;
			species factory aspect: default;
			
			// Mouse interaction for selecting roads to upgrade
			event #mouse_down {
				point click_location <- #user_location;
				road closest_road <- road closest_to click_location;
				
				if (closest_road != nil and (closest_road distance_to click_location) < 20.0) {
					ask world {
						do select_road_for_upgrade(closest_road);
					}
				}
			}
		}
		
//		// GDP Components Chart
//		display "GDP Components" {
//			chart "GDP = C + I + G" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Consumption (C)" value: gdp_consumption color: #green;
//				data "Investment (I)" value: gdp_investment color: #blue;
//				data "Government (G)" value: gdp_government color: #red;
//				data "Total GDP" value: gdp_total color: #yellow style: line;
//			}
//		}
//		
//		// GDP Growth Chart
//		display "GDP Growth" {
//			chart "GDP Over Time" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "GDP" value: gdp_total color: #yellow;
//			}
//		}
//		
//		// Happiness & Productivity
//		display "Happiness & Productivity" {
//			chart "Well-being Metrics" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Average Happiness" value: average_happiness color: #pink;
//				data "Average Productivity (x100)" value: average_productivity * 100 color: #cyan;
//			}
//		}
//		
//		// Infrastructure & Congestion
//		display "Infrastructure" {
//			chart "Road System" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Road Capacity" value: road_capacity color: #green;
//				data "Road Durability" value: road_durability color: #blue;
//				data "Road Congestion" value: road_congestion color: #red;
//			}
//		}
//		
//		// Banking Stability
//		display "Banking System" {
//			chart "Financial Stability" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Bank Capital Ratio" value: bank_capital_ratio color: #blue;
//				data "Loan Default Rate" value: loan_default_rate color: #red;
//				data "Credit Freeze" value: credit_freeze ? 1.0 : 0.0 color: #orange;
//			}
//		}
//		
//		// Employment & Market
//		display "Labor Market" {
//			chart "Employment" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Unemployment Rate" value: unemployment_rate * 100 color: #red;
//				data "Employment Rate" value: (1 - unemployment_rate) * 100 color: #green;
//			}
//		}
//		
//		// Money Flow Monitor
//		display "Money Flow" {
//			chart "Aggregate Balances" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Government Reserves" value: government_reserves color: #purple;
//				data "Bank Capital" value: bank_capital color: #blue;
//				data "Bank Deposits" value: bank_deposits color: #cyan;
//			}
//		}
		
//		// Happiness Goods Economy
//		display "Happiness Goods Market" {
//			chart "Supply Chain" type: series size: {1.0, 0.5} position: {0, 0} {
//				data "Factory Total Inventory" value: sum(factory collect each.happiness_goods_inventory) color: #blue;
//				data "Market Total Stock" value: sum(market collect each.happiness_goods_stock) color: #green;
//				data "Citizen Total Goods" value: sum(citizen collect each.happiness_goods_owned) color: #yellow;
//			}
//		}
	}
}