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
	int level <- 1;
    float height;
    string type;
    int capacity;
    list<inhabitant> residents;
    float total_revenue <- 0.0;
    
    bool is_upgrade <- false;
    date upgrade_time;
    float upgrade_cost <- (shape.area * 500 * level);
    
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
    
    reflex operate_factory when: type = "factory" and current_date.hour = 23 and current_date.minute = 0 {
        total_revenue <- total_revenue - daily_material_cost;
        if (total_revenue < 0) { 
        	total_revenue <- 0.0;
        }
		write "Factory " + name + " after deducting material costs: $" + daily_material_cost;
    }

    aspect default {
        rgb b_color <- #gray;
        if (self = hover_building) { 
        	b_color <- #white;
        }
        
        if (is_upgrade) {
        	b_color <- #brown;
        } else {          
            switch type {
                match "bank" { b_color <- #yellow; }
                match "factory" { b_color <- #orange; }
                match "market" { b_color <- #cyan; }
            }
        }
        draw shape color: b_color border: #black;
        
	    if (type = "factory" and level > 1) {
	            draw "LVL " + level at: location + {0,0,height+2} color: #white size: 10;
        }
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
    		write "You need $" + upgrade_cost + " to upgrade road " + name;
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
            float effective_salary <- salary_per_hour * (1 + (workplace.level - 1) * 0.5); 
	        money <- money + (effective_salary / 60);
	        
	        ask workplace {
	            total_revenue <- total_revenue + 25.0;
	        }
        }
    }
    
    reflex schedule {
        if (current_hour >= 8 and current_hour < 17) {
            if (status != "working") {
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
					if (b != nil and (b distance_to m_pos < 10.0) and b.type = "factory") {
						hover_building <- b;
						ask b {
							do start_upgrade;
						}
//						write "Current revenue: $" + string(b.total_revenue, "#.##");
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
                    if (b != nil and (b distance_to m_pos < 10.0) and b.type = "factory") {
                    	hover_building <- b;
                    } else {
                    	hover_building <- nil;
                    }
                }
            }
            
            overlay position: {20#px, 20#px} size: {280#px, 450#px} background: #gray transparency: 0.2 border: #white {
			    float margin <- 20#px;
			    float y <- 30#px;
			
			    draw "CITY DASHBOARD" at: {margin, y} color: #white font: font("Arial", 18, #bold);
			    y <- y + 10#px;
			    draw line([{margin, y}, {260#px, y}]) color: #gray;
			    
			    y <- y + 30#px;
			    draw string(current_date, "dd/MM/yyyy") at: {margin, y} color: #lightgray font: font("Arial", 12);
			    draw string(current_date, "HH:mm") at: {200#px, y} color: #cyan font: font("Arial", 14, #bold);
			    
			    y <- y + 30#px;
			    draw "City Budget: $" + string(city_budget, "#.##") at: {20#px, y} color: #springgreen;
			    
			    y <- y + 40#px;
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
			
			    y <- y + 50#px;
			    
			    if (hover_building != nil or hover_road != nil) {
			        draw rectangle(240#px, 130#px) at: {140#px, y + 40#px} color: rgb(50, 50, 50, 150) border: #cyan;
			        
			        if (hover_building != nil) {
					    draw "BUILDING: " + hover_building.type at: {margin + 10#px, y + 15#px} color: #cyan font: font("Arial", 12, #bold);
					    
					    draw "Level: " + hover_building.level at: {margin + 10#px, y + 35#px} color: #white font: font("Arial", 10);
					    draw "Area: " + string(hover_building.shape.area, "#") + " m²" at: {margin + 10#px, y + 55#px} color: #white font: font("Arial", 10);
					    
					    draw "Revenue: $" + string(hover_building.total_revenue, "#.##") at: {margin + 10#px, y + 75#px} color: #yellow font: font("Arial", 10);
					    
					    if (hover_building.is_upgrade) {
					        draw "STATUS: UPGRADING..." at: {margin + 10#px, y + 90#px} color: #springgreen font: font("Arial", 11, #italic);
					    } else {
					        draw "Next Upgrade: $" + string(hover_building.upgrade_cost, "#.##") at: {margin + 10#px, y + 90#px} color: #cyan font: font("Arial", 10, #bold);
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
    }
}