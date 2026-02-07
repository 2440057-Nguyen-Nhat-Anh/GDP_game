/**
* Name: main
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/
model main

global {
	float gdp_current <- 0.0;
	float gdp_previous <- 0.0;
	float gdp_growth_rate <- 0.0;
	float total_wages_paid <- 0.0;
	float total_govt_spending <- 0.0;
	float total_private_spending <- 0.0;
	list<float> gdp_history <- [];
	float factory_tax_rate <- 0.15;
	float salary_per_hour <- 12.0;
	float total_goods_produced update: building where (each.type = "factory") sum_of (each.goods);
	file shapefile_buildings <- file("../includes/buildings.shp");
	file shapefile_roads <- file("../includes/roads.shp");
	geometry shape <- envelope(shapefile_roads);
	graph road_network;
	road hover_road <- nil;
	road selected_road <- nil;
	building hover_building <- nil;
	bool waiting_for_factory_selection <- false;
	building selected_factory <- nil;
	map<road, float> new_weight;
	float city_budget <- 400000.0;
	float private_investment <- 1600000.0;
	float total_budget update: city_budget + private_investment;
	float total_money_inhabitants update: inhabitant sum_of (each.money);
	float total_factory_revenue update: building where (each.type = "factory") sum_of (each.total_revenue);
	float daily_material_cost <- 500000.0;
	float step <- 1 #mn;
	date starting_date <- date([2024, 1, 1, 7, 0, 0]);
	int current_hour update: current_date.hour;

	reflex update_speed {
		new_weight <- road as_map (each::(each.shape.perimeter / each.speed_rate));
	}

	reflex calculate_daily_gdp when: (current_date.hour = 23 and current_date.minute = 59) {
		gdp_previous <- gdp_current;
		gdp_current <- total_wages_paid + total_govt_spending + total_private_spending;
		if (gdp_previous > 0) {
			gdp_growth_rate <- ((gdp_current - gdp_previous) / gdp_previous) * 100;
		}

		add gdp_current to: gdp_history;
		write
		"GDP Report " + string(current_date, "dd/MM") + ": $" + string(gdp_current, "#.##") + " [Wages: $" + string(total_wages_paid, "#") + " | Gov: $" + string(total_govt_spending, "#") + " | Private: $" + string(total_private_spending, "#") + "]";
	}

	init {
		create road from: split_lines(shapefile_roads);
		road_network <- as_edge_graph(road);
		create building from: shapefile_buildings with: (height: int(read("HEIGHT")));
		list<building> sorted_buildings <- (building where (each.shape.area > 9000)) sort_by (-each.shape.area);
		ask 8 among sorted_buildings {
			type <- "factory";
		}

		list<building> frontage <- building where (each.type = nil and each distance_to (road closest_to each) < 15.0);
		ask 5 among frontage {
			type <- "bank";
		}

		ask 10 among frontage {
			type <- "market";
		}

		ask building where (each.type = nil) {
			type <- "home";
			capacity <- 4;
		}

		create inhabitant number: 1000 {
			home <- one_of(building where (each.type = "home" and length(each.residents) < each.capacity));
			if (home != nil) {
				location <- any_location_in(home);
				add self to: home.residents;
			} else {
				home <- one_of(building where (each.type = "home"));
				location <- any_location_in(home);
			}

			workplace <- one_of(building where (each.type = "factory"));
			money <- rnd(100.0, 500.0);
		}

		ask building where (each.type = "factory") {
			int num_workers <- length(inhabitant where (each.workplace = self));
			int days_capital <- rnd(15, 30);
			float initial_capital <- (num_workers * 9 * salary_per_hour * days_capital);
			total_revenue <- initial_capital;
			goods <- rnd(200000.0, 400000.0);
			write "Factory " + name + " initialized with " + num_workers + " workers, $" + initial_capital + " capital (" + days_capital + " days), and " + goods + " goods";
		} } }

species building {
	int level <- 1;
	float height;
	string type;
	int capacity;
	list<inhabitant> residents;
	float total_revenue <- 0.0;
	float goods <- 0.0;
	int days_without_payment <- 0;
	bool in_debt <- false;
	bool is_upgrade <- false;
	date upgrade_time;
	float upgrade_cost <- (shape.area * 500 * level);

	action start_upgrade {
		if (type = "factory" and !is_upgrade and city_budget >= upgrade_cost) {
			city_budget <- city_budget - upgrade_cost;
			is_upgrade <- true;
			upgrade_time <- current_date + 5 #day;
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

	reflex pay_workers when: type = "factory" and current_date.hour = 17 and current_date.minute = 0 {
		int num_workers <- length(inhabitant where (each.workplace = self));
		float daily_payroll <- num_workers * 9 * salary_per_hour * (1 + (level - 1) * 0.5);
		if (total_revenue >= daily_payroll) {
			ask inhabitant where (each.workplace = self) {
				float daily_salary <- 9 * salary_per_hour * (1 + (myself.level - 1) * 0.5);
				money <- money + daily_salary;
			}

			total_revenue <- total_revenue - daily_payroll;
			total_wages_paid <- total_wages_paid + daily_payroll;
			days_without_payment <- 0;
			in_debt <- false;
		} else {
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
			b_color <- #red;
		} else if (is_upgrade) {
			b_color <- #brown;
		} else {
			switch type {
				match "bank" {
					b_color <- #yellow;
				}

				match "factory" {
					b_color <- #orange;
				}

				match "market" {
					b_color <- #cyan;
				}

			}

		}

		if (self = hover_building) {
			b_color <- #blue;
		}

		draw shape color: b_color border: #black;
		if (type = "factory" and level > 1) {
			draw "LVL " + level at: location + {0, 0, height + 2} color: #white size: 10;
		}

	}

}

species road {
	int level <- 1;
	float capacity <- (1 + shape.perimeter / 30) * 2 ^ (level - 1);
	int nb_drivers <- 0 update: length(inhabitant where (each.current_road = self));
	float speed_rate <- 1.0 update: exp(-nb_drivers / capacity) min: 0.2;
	float upgrade_cost <- shape.perimeter * 200 * level;
	float material_cost <- shape.perimeter * 500 * level;
	bool is_under_construction <- false;
	bool waiting_to_upgrade <- false;
	date construction_end_time;

	action start_upgrade {
		if (!is_under_construction and !waiting_to_upgrade) {
			if (total_budget >= upgrade_cost) {
				write "Budget OK ($" + upgrade_cost + "). Material needed: " + material_cost + " units. Select a factory...";
				return true;
			} else {
				write "Insufficient budget! Need $" + upgrade_cost + " (have $" + total_budget + ")";
				return false;
			}

		} else if (waiting_to_upgrade) {
			write "Road upgrade already pending - waiting for drivers to leave (" + nb_drivers + " remaining)";
			return false;
		} else {
			write "Road is already under construction";
			return false;
		}

	}

	action confirm_upgrade_with_factory (building factory) {
		if (factory.goods < material_cost) {
			write "Factory " + factory.name + " only has " + factory.goods + " goods (need " + material_cost + ")";
			return;
		}

		float govt_share <- upgrade_cost * 0.20;
		float private_share <- upgrade_cost * 0.80;
		float govt_payment <- min(govt_share, city_budget);
		float private_payment <- min(private_share, private_investment);
		float total_available <- govt_payment + private_payment;
		if (total_available < upgrade_cost) {
			write "Insufficient total budget! Need $" + upgrade_cost + " (have $" + total_available + ")";
			return;
		}

		if (govt_payment < govt_share) {
			private_payment <- upgrade_cost - govt_payment;
		} else if (private_payment < private_share) {
			govt_payment <- upgrade_cost - private_payment;
		}

		float factory_profit <- upgrade_cost * 0.07;
		float profit_tax <- factory_profit * 0.20;
		float factory_net_revenue <- upgrade_cost - profit_tax;
		city_budget <- city_budget - govt_payment + profit_tax;
		private_investment <- private_investment - private_payment;
		total_govt_spending <- total_govt_spending + govt_payment;
		total_private_spending <- total_private_spending + private_payment;
		ask factory {
			total_revenue <- total_revenue + factory_net_revenue;
		}

		is_under_construction <- true;
		construction_end_time <- current_date + 1 #day;
		write "Road upgrade started! Govt: $" + govt_payment + " + Private: $" + private_payment + ". Factory " + factory.name + " paid $" + factory_net_revenue;
	}

	reflex start_upgrade_when_clear when: waiting_to_upgrade {
		if (nb_drivers = 0) {
			city_budget <- city_budget - upgrade_cost;
			waiting_to_upgrade <- false;
			is_under_construction <- true;
			construction_end_time <- current_date + 1 #day;
			write "Road cleared! Construction starting now. Expected completion: " + string(construction_end_time);
		}

	}

	reflex check_construction_finished when: is_under_construction {
		if (current_date >= construction_end_time) {
			is_under_construction <- false;
			level <- level + 1;
			capacity <- (1 + shape.perimeter / 30) * 2 ^ (level - 1);
			write "Road upgrade complete! New level: " + level + " | Capacity increased!";
			is_under_construction <- false;
		}

	}

	aspect default {
		rgb road_color;
		if (is_under_construction) {
			road_color <- #brown;
		} else if (waiting_to_upgrade) {
			road_color <- #orange;
		} else if (self = selected_road) {
			road_color <- #purple;
		} else if (self = hover_road) {
			road_color <- #blue;
		} else {
			float traffic_ratio <- (1 - (speed_rate / level));
			road_color <- blend(#red, #pink, max(0.0, min(1.0, traffic_ratio)));
		}

		float display_width <- (1 + level + 2 * (1 - min(1.0, speed_rate / level)));
		draw (shape buffer display_width) color: road_color;
		if (level > 1 and !is_under_construction) {
			draw "L" + level at: location color: #white size: 8;
		} } }

species inhabitant skills: [moving] {
	point target;
	building home;
	building workplace;
	road current_road;
	string status <- "resting";
	float money;
	float speed <- 5 #km / #h;
	int time_buffer <- int(gauss(30, 15)) min: 0 max: 60;

	reflex move when: (target != nil) {
		road closest_road <- road closest_to self;
		if (closest_road != nil and (self distance_to closest_road) < 5.0) {
			if (current_road != closest_road) {
				current_road <- closest_road;
			}

			if (current_road.is_under_construction) {
				speed <- 0.5 #km / #h;
			} else {
				speed <- (5 #km / #h) * current_road.speed_rate;
			}

		} else {
			current_road <- nil;
			speed <- 5 #km / #h;
		}

		do goto target: target on: road_network move_weights: new_weight;
		if (location = target) {
			target <- nil;
			current_road <- nil;
		}

	}

	reflex produce_goods when: status = "working" and (current_hour >= 8 and current_hour < 17) {
		if (location overlaps workplace.shape) {
			ask workplace {
				goods <- goods + 1.0;
			}

		}

	}

	reflex visit_bank when: status = "moving_free" {
		list<building> banks <- building where (each.type = "bank");
		loop b over: banks {
			if (location overlaps b.shape and money > 0) {
				float tax_amount <- money * 0.15;
				city_budget <- city_budget + tax_amount;
				float investment_amount <- money * 0.80;
				private_investment <- private_investment + investment_amount;
				money <- money * 0.05;
				break;
			}

		}

	}

	reflex schedule {
		int current_minutes <- current_date.hour * 60 + current_date.minute;
		int work_departure_time <- 7 * 60 + 30 + time_buffer;
		int work_end_time <- 17 * 60 + time_buffer;
		if (current_minutes >= work_departure_time and current_minutes < work_end_time and status != "working") {
			if (!workplace.is_upgrade) {
				target <- any_location_in(workplace);
				status <- "working";
			} else {
				building destination <- one_of(building where (each.type = "market" or each.type = "bank"));
				if (destination != nil) {
					target <- any_location_in(destination);
					status <- "moving_free";
				}

			}

		} else if (current_minutes >= work_end_time and status = "working") {
			building destination <- one_of(building where (each.type = "market" or each.type = "bank"));
			if (destination != nil) {
				target <- any_location_in(destination);
				status <- "moving_free";
			}

			if (location = destination) {
				destination <- nil;
			}

		} else if (current_hour >= 22 or current_hour < 6) {
			if (status != "resting") {
				target <- any_location_in(home);
				status <- "resting";
			}

		} else if ((current_hour >= 6 and current_minutes < work_departure_time) or (current_minutes >= work_end_time and current_hour < 22)) {
			if (target = nil and status != "moving_free") {
				float r <- rnd(0.0, 1.0);
				if (r < 0.2) {
					building target_b <- one_of(building where (each.type = "market" or each.type = "bank"));
					if (target_b != nil) {
						target <- any_location_in(target_b);
						status <- "moving_free";
					}

				}

			}

		} }

	aspect default {
		draw circle(5) color: #lightgreen;
	} }

experiment project type: gui {
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
					if (waiting_for_factory_selection and selected_road != nil) {
						building b <- building closest_to m_pos;
						if (b != nil and b.type = "factory" and (b distance_to m_pos < 10.0)) {
							selected_factory <- b;
							ask selected_road {
								do confirm_upgrade_with_factory(myself.selected_factory);
							}

							waiting_for_factory_selection <- false;
							selected_road <- nil;
							selected_factory <- nil;
						} else {
							write "❌ Road upgrade cancelled. Click a road to start again.";
							selected_road <- nil;
							waiting_for_factory_selection <- false;
						}

					} else {
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
					road r <- road closest_to m_pos;
					if (r != nil and (r distance_to m_pos < 15.0)) {
						hover_road <- r;
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

			overlay position: {20 #px, 20 #px} size: {280 #px, 470 #px} background: #gray transparency: 0.2 border: #white {
				float margin <- 20 #px;
				float y <- 30 #px;
				draw "CITY DASHBOARD" at: {margin, y} color: #white font: font("Arial", 18, #bold);
				y <- y + 10 #px;
				draw line([{margin, y}, {260 #px, y}]) color: #gray;
				y <- y + 30 #px;
				draw string(current_date, "dd/MM/yyyy") at: {margin, y} color: #lightgray font: font("Arial", 12);
				draw string(current_date, "HH:mm") at: {200 #px, y} color: #cyan font: font("Arial", 14, #bold);
				y <- y + 30 #px;
				draw "Government Budget: $" + string(city_budget, "#.##") at: {margin, y} color: #springgreen font: font("Arial", 10);
				y <- y + 20 #px;
				draw "Private Investment: $" + string(private_investment, "#.##") at: {margin, y} color: #gold font: font("Arial", 10);
				y <- y + 20 #px;
				draw "Total Budget: $" + string(total_budget, "#.##") at: {margin, y} color: #white font: font("Arial", 11, #bold);
				y <- y + 30 #px;
				draw "FACILITY TYPES" at: {margin, y} color: #cyan font: font("Arial", 11, #bold);
				y <- y + 5 #px;
				draw line([{margin, y}, {150 #px, y}]) color: #cyan;
				y <- y + 25 #px;
				draw rectangle(12 #px, 12 #px) at: {margin + 6 #px, y} color: #orange;
				draw "Factory" at: {margin + 25 #px, y + 5 #px} color: #white font: font("Arial", 11);
				draw rectangle(12 #px, 12 #px) at: {margin + 120 #px, y} color: #yellow;
				draw "Bank" at: {margin + 140 #px, y + 5 #px} color: #white font: font("Arial", 11);
				y <- y + 25 #px;
				draw rectangle(12 #px, 12 #px) at: {margin + 6 #px, y} color: #cyan;
				draw "Market" at: {margin + 25 #px, y + 5 #px} color: #white font: font("Arial", 11);
				draw rectangle(12 #px, 12 #px) at: {margin + 120 #px, y} color: #gray;
				draw "Home" at: {margin + 140 #px, y + 5 #px} color: #white font: font("Arial", 11);
				y <- y + 25 #px;
				draw "City GDP: $" + string(world.gdp_current, "#.##") at: {margin, y} color: #cyan font: font("Arial", 11, #bold);
				y <- y + 18 #px;
				rgb growth_color <- (world.gdp_growth_rate >= 0) ? #springgreen : #red;
				draw "Growth: " + string(world.gdp_growth_rate, "#.#") + "%" at: {margin, y} color: growth_color font: font("Arial", 10);
				y <- y + 25 #px;
				draw "Total Goods: " + string(world.total_goods_produced, "#") + " units" at: {margin, y} color: #springgreen font: font("Arial", 11, #bold);
				y <- y + 50 #px;
				if (hover_building != nil or hover_road != nil) {
					draw rectangle(240 #px, 150 #px) at: {140 #px, y + 40 #px} color: rgb(50, 50, 50, 150) border: #cyan;
					if (hover_building != nil) {
						draw "BUILDING: " + hover_building.type at: {margin + 10 #px, y} color: #cyan font: font("Arial", 12, #bold);
						draw "Level: " + hover_building.level at: {margin + 10 #px, y + 20 #px} color: #white font: font("Arial", 10);
						draw "Area: " + string(hover_building.shape.area, "#") + " m²" at: {margin + 10 #px, y + 40 #px} color: #white font: font("Arial", 10);
						if (hover_building.type = "factory") {
							draw "Budget: $" + string(hover_building.total_revenue, "#.##") at: {margin + 10 #px, y + 60 #px} color: #yellow font: font("Arial", 10);
							draw "Materials: " + string(hover_building.goods, "#") + " units" at: {margin + 10 #px, y + 80 #px} color: #springgreen font: font("Arial", 10);
						}

						if (hover_building.is_upgrade) {
							draw "STATUS: UPGRADING..." at: {margin + 10 #px, y + 100 #px} color: #springgreen font: font("Arial", 11, #italic);
						} else {
							draw "Next Upgrade: $" + string(hover_building.upgrade_cost, "#.##") at: {margin + 10 #px, y + 100 #px} color: #cyan font: font("Arial", 10, #bold);
						}

					} else if (hover_road != nil) {
						draw "ROAD SECTOR" at: {margin + 10 #px, y + 20 #px} color: #cyan font: font("Arial", 12, #bold);
						draw "Current Level: " + hover_road.level at: {margin + 10 #px, y + 45 #px} color: #white;
						if (hover_road.is_under_construction) {
							draw "STATUS: WORK IN PROGRESS" at: {margin + 10 #px, y + 70 #px} color: #springgreen;
						} else {
							draw "Upgrade: $" + string(hover_road.upgrade_cost, "#.##") at: {margin + 10 #px, y + 70 #px} color: #cyan;
						}

					}

				} else {
					draw "Select a building or road" at: {margin, y + 20 #px} color: #gray font: font("Arial", 11, #italic);
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