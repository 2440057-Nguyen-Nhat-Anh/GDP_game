/**
* Name: main
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model main

global {
    float factory_tax_rate <- 0.15;
    float salary_per_hour <- 12.0;

    file shapefile_buildings <- file("../includes/buildings.shp");
    file shapefile_roads <- file("../includes/roads.shp");
    
    geometry shape <- envelope(shapefile_roads);
    graph road_network;
    
    road hover_road <- nil;
    road selected_road <- nil;
    building hover_building <- nil;
    
    map<road, float> new_weight;

    float city_budget <- 0.0;
    float total_money_inhabitants update: inhabitant sum_of (each.money);
    float total_factory_revenue update: building where (each.type = "factory") sum_of (each.total_revenue);
    
    float daily_material_cost <- 500000.0;
        
    float step <- 1#mn;
    date starting_date <- date([2024, 1, 1, 7, 0, 0]);
    int current_hour update: current_date.hour;
    
    reflex update_speed {
		new_weight <- road as_map (each::(each.is_under_construction ? 1000000.0 : (each.shape.perimeter / each.speed_rate)));
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
        ask 5 among frontage { type <- "bank"; }
        ask 10 among frontage { type <- "market"; }
        
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
    }
}

species building {
    float height;
    string type;
    int capacity;
    list<inhabitant> residents;
    float total_revenue <- 0.0;
    
    reflex pay_taxes when: type = "factory" and current_date.hour = 0 and current_date.minute = 0 {
        float tax_amount <- total_revenue * factory_tax_rate;
        city_budget <- city_budget + tax_amount;
        total_revenue <- total_revenue - tax_amount;
    }
    
    reflex operate_factory when: type = "factory" and current_date.hour = 23 and current_date.minute = 0 {
        total_revenue <- total_revenue - daily_material_cost;
        if (total_revenue < 0) { 
        	total_revenue <- 0.0;
        }
		write "Factory " + name + " after deducting material costs: $" + daily_material_cost;
    }

    aspect default {
        rgb b_color <- #gray;
        if (self = hover_building) { b_color <- #white; }
        else {          
            switch type {
                match "bank" { b_color <- #yellow; }
                match "factory" { b_color <- #orange; }
                match "market" { b_color <- #cyan; }
            }
        }
        draw shape color: b_color border: #black;
    }
}

species road {
	int level <- 1;
    float capacity <- (1 + shape.perimeter / 30) * level;
    int nb_drivers <- 0 update: length(inhabitant at_distance 1.0);
    float speed_rate <- (1.0 * level) update: (exp(-nb_drivers / capacity) * level) min: 0.1;
    
    float upgrade_cost <- shape.perimeter * 2000 * level;
    bool is_under_construction <- false;
    date construction_end_time;
    
    action start_upgrade {
    	if (!is_under_construction and city_budget >= upgrade_cost) {
    		city_budget <- city_budget - upgrade_cost;
    		is_under_construction <- true;
    		construction_end_time <- current_date + 1#day;
    		write "Road " + road +"upgrade in progress. Expected completion date: " + string(construction_end_time);
    	} else {
    		write upgrade_cost;
    	}
    }
    
    reflex check_construction_finished when: is_under_construction {
        if (current_date >= construction_end_time) {
            is_under_construction <- false;
            level <- level + 1;
            capacity <- (1 + shape.perimeter / 30) * level;
            write "Road upgraded successfully. " + road + " has reached level: " + level;
            is_under_construction <- false;
        }
    }
    
    aspect default {
    rgb road_color;
    
    if (is_under_construction) {
        road_color <- #brown;
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

species inhabitant skills: [moving] {
    point target;
    building home;
    building workplace;
    string status <- "resting";
    float money;
    float speed <- 5 #km/#h;

    reflex move when: (target != nil) {
        do goto target: target on: road_network move_weights: new_weight;
        if (location = target) { target <- nil; }
    }
    
    reflex earn_money when: status = "working" and (current_hour >= 8 and current_hour < 17) {
        if (location overlaps workplace.shape) {
            money <- money + (salary_per_hour / 60);
            ask workplace {
                total_revenue <- total_revenue + 25.0;
            }
        }
    }
    
    reflex schedule {
        if (current_hour >= 8 and current_hour < 17) {
            if (status != "working") {
                target <- any_location_in(workplace);
                status <- "working";
            }
        } else if (current_hour >= 22 or current_hour < 6) {
            if (status != "resting") {
                target <- any_location_in(home);
                status <- "resting";
            }
        } else {
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
        }
    }
        
    aspect default {
        draw circle(5) color: #lightgreen;
    }
}

experiment project type: gui {
    parameter "Factory Tax Rate" var: factory_tax_rate category: "Policy";
    parameter "Salary per Hour" var: salary_per_hour category: "Policy";
    parameter "Daily Material Cost" var: daily_material_cost min: 0.0 max: 5000000.0;
    
    output {
        display map type: 3d axes: false background: #black {
            species building aspect: default;
            species road aspect: default;           
            species inhabitant aspect: default;
            
            event mouse_down {
				point m_pos <- #user_location;
				
				ask world {
//					ask road {
//						is_selected <- false;
//					}
					road r <- road closest_to m_pos;
					if (r != nil and (r distance_to m_pos < 15.0)) {
						selected_road <- r;
//						r.is_selected <- true;
						ask r {
							do start_upgrade;
						}
					} else {
						selected_road <- nil;
					}
					
					building b <- building closest_to m_pos;
					if (b != nil and (b distance_to m_pos < 10.0)) {
						hover_building <- b;
						write "Current revenue: $" + string(b.total_revenue, "#.##");
					} else {
						hover_building <- nil;
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
                    if (b != nil and (b distance_to m_pos < 10.0)) {
                    	hover_building <- b;
                    } else {
                    	hover_building <- nil;
                    }
                }
            }
            
            overlay position: {20#px, 20#px} size: {250#px, 350#px} background: #white transparency: 0.2 {
                draw "CITY STATS" at: {20#px, 30#px} color: #black font: font("Arial", 16, #bold);
                draw "Date: " + string(current_date, "DD/MM/YYYY") at: {20#px, 60#px} color: #black;
                draw "Time: " + string(current_date, "HH:mm") at: {20#px, 90#px} color: #black;
                draw "City Budget: $" + string(city_budget, "#.##") at: {20#px, 120#px} color: #darkblue;
                
                draw "LEGEND" at: {20#px, 170#px} color: #black font: font("Arial", 14, #bold);
                draw square(10#px) at: {30#px, 200#px} color: #orange; draw "Factory" at: {50#px, 235#px} color: #black;
                draw square(10#px) at: {30#px, 230#px} color: #yellow; draw "Bank" at: {50#px, 265#px} color: #black;
                draw square(10#px) at: {30#px, 260#px} color: #cyan; draw "Market" at: {50#px, 295#px} color: #black;
            }
        }
    }
}